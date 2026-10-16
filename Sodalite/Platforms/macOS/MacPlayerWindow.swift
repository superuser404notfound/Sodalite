import SwiftUI
import AppKit

/// The one session the player window shows, handed over by whichever launcher started it.
///
/// A window scene cannot be given a view model directly (`openWindow` takes only a Codable value),
/// so the launchers park the session here and the scene reads it back. There is one player window,
/// not one per title: a second Play replaces what the window is showing rather than stacking a
/// second engine decoding beside the first.
@MainActor
@Observable
final class MacPlayerWindowSession {
    static let shared = MacPlayerWindowSession()
    static let windowID = "player"
    /// The one value the player window is opened with. Opening a `WindowGroup` by value brings the
    /// window already showing that value forward instead of adding another, which is what keeps
    /// this group to a single window.
    static let windowValue = "player"

    struct Entry {
        let viewModel: PlayerViewModel
        let theme: ResolvedAppearanceTheme
        /// Tells the launcher its player is gone, whichever way it went: Escape, the close button,
        /// or a newer session taking the window over.
        let onClose: () -> Void
    }

    private(set) var current: Entry?
    private var started = false

    func show(_ entry: Entry) {
        let replaced = current
        if let replaced { tearDown(replaced) }
        current = entry
        started = false
        PlayerModalPresence.claimPlayerActive()
        replaced?.onClose()
    }

    /// Called by the screen whenever it appears. Only the first call starts playback: the screen
    /// appears again after every full screen transition, and that is not a new session.
    func startIfNeeded(_ viewModel: PlayerViewModel) {
        guard current?.viewModel === viewModel, !started else { return }
        started = true
        viewModel.beginPlayback()
    }

    /// Clears the window's session only if it is still this one, so a launcher tearing down late
    /// cannot close a player that a newer launcher has since put up.
    func end(_ viewModel: PlayerViewModel) {
        guard let ended = current, ended.viewModel === viewModel else { return }
        tearDown(ended)
        current = nil
        ended.onClose()
    }

    /// Playback ends with the session, never with a view: SwiftUI takes the window's content off
    /// screen and back while it moves the window into and out of its full screen space, and a
    /// player stopped from `onDisappear` closed itself every time it went full screen.
    private func tearDown(_ entry: Entry) {
        entry.viewModel.stopPlayback()
        PlayerModalPresence.releasePlayerActive()
    }
}

/// The player window's scene. Not restored on relaunch: the session it would restore is gone.
///
/// A `WindowGroup`, not a single-instance `Window`, because SwiftUI makes a `Window` a full screen
/// auxiliary, a window that can only join another one's full screen space: the green button,
/// Ctrl-Cmd-F and the player's own F all did nothing, and `windowFullScreenBehavior(.enabled)` only
/// changes which of the two kinds of auxiliary it is.
struct MacPlayerWindowScene: Scene {
    private static func placement(on display: DisplayProxy) -> WindowPlacement {
        let visible = display.visibleRect
        let width = min(1280, visible.width * 2 / 3)
        let size = CGSize(width: width, height: (width * 9 / 16).rounded())
        return WindowPlacement(
            CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2),
            size: size
        )
    }

    var body: some Scene {
        WindowGroup("player.window.title", id: MacPlayerWindowSession.windowID, for: String.self) { _ in
            MacPlayerWindowContent()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        // Opens centred at 16:9 and at most two thirds of the display, and zooms back to that;
        // `MacPlayerScreen` reshapes it to the source once that is known.
        .defaultWindowPlacement { _, context in Self.placement(on: context.defaultDisplay) }
        .windowIdealPlacement { _, context in Self.placement(on: context.defaultDisplay) }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct MacPlayerWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hostWindow = HostWindowReference()
    private let session = MacPlayerWindowSession.shared

    var body: some View {
        Group {
            if let entry = session.current {
                MacPlayerScreen(viewModel: entry.viewModel, theme: entry.theme) {
                    session.end(entry.viewModel)
                }
                // A replaced session is a new screen, so the old one's onDisappear stops its engine.
                .id(ObjectIdentifier(entry.viewModel))
                .navigationTitle(PlayerTitleLines(item: entry.viewModel.item, spoilerPolicy: entry.viewModel.spoilerPolicy).header)
            } else {
                Color.black
            }
        }
        .background(HostWindowReader(reference: hostWindow))
        .onChange(of: session.current == nil) { _, ended in
            if ended { dismissWindow(id: MacPlayerWindowSession.windowID) }
        }
        // The window's own close button: the session has to end with it, or the launcher would
        // still believe its player is up. The close itself, not `onDisappear`, which also fires on
        // the way into full screen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let closing = note.object as? NSWindow, closing === hostWindow.window,
                  let viewModel = session.current?.viewModel else { return }
            session.end(viewModel)
        }
    }
}

/// What both launchers do with the session they build: put it in the window, and take it back out
/// when their binding says the player is over.
struct MacPlayerWindowPresenter: ViewModifier {
    @Binding var session: PlayerViewModel?
    let theme: ResolvedAppearanceTheme
    let onClose: () -> Void

    @Environment(\.openWindow) private var openWindow
    /// The session this launcher put in the window, so dropping it ends that one and never a newer
    /// one another launcher has put up since.
    @State private var shown: PlayerViewModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: session.map(ObjectIdentifier.init), initial: true) { _, _ in
                if let previous = shown, previous !== session {
                    MacPlayerWindowSession.shared.end(previous)
                }
                shown = session
                guard let viewModel = session else { return }
                MacPlayerWindowSession.shared.show(.init(viewModel: viewModel, theme: theme, onClose: onClose))
                openWindow(id: MacPlayerWindowSession.windowID, value: MacPlayerWindowSession.windowValue)
            }
    }
}

/// The window a view is in, read off the view itself rather than `NSApp.keyWindow`, which is the
/// library window whenever that one was clicked last.
final class HostWindowReference {
    weak var window: NSWindow?
}

struct HostWindowReader: NSViewRepresentable {
    let reference: HostWindowReference

    func makeNSView(context: Context) -> NSView {
        WindowTrackingView(reference: reference)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowTrackingView: NSView {
        let reference: HostWindowReference

        init(reference: HostWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { reference.window = window }
        }
    }
}
