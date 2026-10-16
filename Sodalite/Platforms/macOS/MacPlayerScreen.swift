import SwiftUI
import AppKit
import AetherEngine

/// The Mac's player: the engine's render surface with a pointer-and-keyboard transport over it.
///
/// Deliberately not a port of `PlayerOverlayView`. That overlay is display-only by construction
/// because `PlayerHostController` owns every press and moves a cursor through the controls for it,
/// which is what a remote needs and what a pointer makes pointless. Here the controls are ordinary
/// SwiftUI controls that handle their own clicks, and the keyboard reaches them through
/// `onKeyPress` rather than through a responder chain.
struct MacPlayerScreen: View {
    let viewModel: PlayerViewModel
    let theme: ResolvedAppearanceTheme
    let onDismiss: () -> Void

    /// The chrome hides itself while the pointer is still and comes back when it moves, so a window
    /// left alone is just the picture. Keyboard transport works either way.
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var hostWindow = HostWindowReference()

    private var titleLines: PlayerTitleLines { PlayerTitleLines(item: viewModel.item, spoilerPolicy: viewModel.spoilerPolicy) }

    var body: some View {
        ZStack {
            Color.black
            AetherPlayerSurface(engine: viewModel.player)
            // The title bar is hidden, so the picture is the handle. A layer of its own, under the
            // chrome, so dragging never steals a press meant for the transport (Apple's Destination
            // Video sample layers it the same way).
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)

            if viewModel.isLoading, viewModel.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let message = viewModel.errorMessage {
                errorPanel(message: message)
            } else {
                chrome
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            }
        }
        .ignoresSafeArea()
        .background(HostWindowReader(reference: hostWindow))
        .frame(minWidth: 720, minHeight: 405)
        .frame(idealWidth: 1280, idealHeight: 720)
        .preferredColorScheme(.dark)
        .tint(theme.palette.control.color)
        .onChange(of: viewModel.isLoading) { _, loading in
            if !loading { fitWindow(to: viewModel.videoSize) }
        }
        .onChange(of: controlsVisible) { _, visible in
            setWindowChromeVisible(visible)
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .task {
            MacPlayerWindowSession.shared.startIfNeeded(viewModel)
            revealControls()
        }
        // A monitor on the window rather than `onKeyPress`: that needs a focused view, and a click
        // anywhere on the picture lands on the drag layer, which takes focus away from it, so the
        // keys died the first time anyone moved the window.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === hostWindow.window, handle(event) else { return event }
                return nil
            }
        }
        .onDisappear {
            hideTask?.cancel()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            // Centred in the title bar's band, the way QuickTime titles a window it has hidden the
            // title bar of: the traffic lights keep the leading corner and close the window.
            VStack(spacing: 2) {
                Text(titleLines.header)
                    .font(.headline)
                if let subtitle = titleLines.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 96)
            .padding(.top, 8)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 0)

            transport
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 180)
                        .allowsHitTesting(false)
                }
        }
        .foregroundStyle(.white)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            // Bound to the view model's own scrub state, so a drag reads the position it is dragging
            // to while the committed one keeps arriving from the engine behind it.
            Slider(
                value: Binding(
                    get: { Double(viewModel.displayedProgress) },
                    set: { viewModel.scrub(toFraction: Float($0)) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { viewModel.commitScrub() }
                    revealControls()
                }
            )

            HStack(spacing: 16) {
                Text(viewModel.isScrubbing ? viewModel.scrubTime : viewModel.currentTime)
                    .monospacedDigit()

                Spacer(minLength: 0)

                transportButton("gobackward.10") { skip(direction: -1) }
                transportButton(viewModel.isPlaying ? "pause.fill" : "play.fill", size: .title) {
                    viewModel.togglePlayPause()
                }
                transportButton("goforward.10") { skip(direction: 1) }

                Spacer(minLength: 0)

                transportButton("arrow.up.left.and.arrow.down.right", size: .body, action: toggleFullScreen)
                Text(viewModel.remainingTime)
                    .monospacedDigit()
            }
            .font(.callout)
        }
    }

    private func transportButton(
        _ systemImage: String,
        size: Font = .title3,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            revealControls()
        } label: {
            Image(systemName: systemImage)
                .font(size)
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorPanel(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.errorIcon ?? "exclamationmark.triangle")
                .font(.system(size: 44))
            if let title = viewModel.errorTitle {
                Text(title).font(.title2.weight(.semibold))
            }
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                if viewModel.canRetryAfterOutage {
                    Button("player.error.retry") { viewModel.retryAfterOutage() }
                }
                Button("common.back", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    // MARK: - Input

    /// True when the key was the player's. Anything with Command, Control or Option held goes on
    /// to the menus, so Cmd-W and Ctrl-Cmd-F keep working.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49:
            viewModel.togglePlayPause()
        case 123:
            skip(direction: -1)
        case 124:
            skip(direction: 1)
        case 53:
            // Leave full screen first, the way QuickTime does: Escape in full screen means "give me
            // the window back", and only then "close the player".
            if isFullScreen {
                toggleFullScreen()
            } else {
                close()
            }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen()
            case "k": viewModel.togglePlayPause()
            default: return false
            }
        }
        revealControls()
        return true
    }

    /// A keyboard or a click asks for the jump and gets it now: unlike a remote there is no burst
    /// of presses to coalesce, so there is nothing to wait for.
    private func skip(direction: Int) {
        viewModel.seekJumpByConfiguredInterval(direction: direction)
        viewModel.commitScrub()
    }

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func close() {
        hideTask?.cancel()
        onDismiss()
    }

    // MARK: - Window

    private var window: NSWindow? { hostWindow.window }

    private var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    /// The traffic lights go with the rest of the chrome, and so does the pointer, so a still
    /// window is nothing but the picture. Moving the mouse brings back all three.
    private func setWindowChromeVisible(_ visible: Bool) {
        if let titlebar = window?.standardWindowButton(.closeButton)?.superview {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                titlebar.animator().alphaValue = visible ? 1 : 0
            }
        }
        if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    /// Locks the window to the picture's shape, so resizing never adds bars, and reshapes it once
    /// now around its current width. The window opens at 16:9 before the source is known.
    private func fitWindow(to videoSize: CGSize) {
        guard let window, videoSize.width > 0, videoSize.height > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        window.contentAspectRatio = videoSize
        var frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let height = (content.width * videoSize.height / videoSize.width).rounded()
        frame.origin.y += content.height - height
        frame.size.height += height - content.height
        window.setFrame(frame, display: true, animate: true)
    }

    private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}
