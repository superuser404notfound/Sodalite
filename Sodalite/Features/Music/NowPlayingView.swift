import SwiftUI

// MARK: - NowPlayingView

struct NowPlayingView: View {
    /// Explicit close from the presenter (AppRouter flips its showNowPlaying binding). More reliable
    /// than @Environment(\.dismiss) for this coordinator-driven fullScreenCover; falls back to dismiss.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        let coordinator = dependencies.musicPlaybackCoordinator
        NowPlayingContent(coordinator: coordinator, close: onClose ?? { dismiss() })
    }
}

// MARK: - NowPlayingContent

/// Isolated view to read coordinator state via `@State` without capturing `dismiss` in closures that
/// outlive the view tree.
private struct NowPlayingContent: View {
    let coordinator: MusicPlaybackCoordinator
    let close: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Transport-row focus, so default focus lands on Play/Pause.
    @FocusState private var transportFocus: TransportButton?

    /// Queue-row focus, lifted out of the rows so the parent can see it (Sodalite#110): moving through
    /// the queue has to reset the idle timer, and a row's own `@FocusState` never leaves the row.
    @FocusState private var queueFocus: String?

    /// tvOS only: the idle auto-hide for the whole chrome (queue, transport, scrubber). It starts
    /// revealed and stays revealed forever on every other platform, where nothing schedules the timer.
    @State private var chromeRevealed = true
    @State private var chromeHideTask: Task<Void, Never>?

    /// Last measured height of the transport + scrubber block, so hiding it can leave half of it
    /// standing. Measured rather than added up, since the time labels follow the text metrics.
    @State private var chromeHeight: CGFloat = 0

    private static let chromeSwap = Animation.easeInOut(duration: 0.35)

    /// Room a focused queue row needs on each side. A `ScrollView` clips to its own bounds, and a row
    /// fills the column exactly, so `QueueRow`'s focus `scaleEffect(1.015)` pushed its left edge, tinted
    /// stroke and shadow straight into that clip. Inset the column's content instead of widening the
    /// scroll area: the header stays aligned with the rows, which a negative padding on the ScrollView
    /// alone would have broken. 20pt covers the ~8pt overhang plus the shadow's blur.
    private static let focusOverhang: CGFloat = 20

    var body: some View {
        ZStack {
            // Opaque base: the cover must never show the tab UI, and the blurred-art layer isn't
            // opaque (transparent placeholder while loading; the 0.65 dim + heavy blur stay
            // see-through). Solid black guarantees full cover.
            Color.black
                .ignoresSafeArea()

            backgroundArt

            contentLayout
        }
        #if os(tvOS)
        // The chrome takes every focusable view with it, so something has to stay behind to read the
        // press or swipe that brings it back. See `NowPlayingWakeSink` for why being alone is the point.
        .overlay {
            if !chromeRevealed {
                NowPlayingWakeSink(wake: { revealChrome() })
                    .ignoresSafeArea()
            }
        }
        #endif
        // tvOS overscans behind the system safe area (manual padding handles the margin); on a phone
        // the content must respect the safe area so the cover/transport clear the notch and home bar.
        .modifier(FullBleedSafeArea(active: hSizeClass != .compact))
        #if os(iOS)
        // tvOS dismisses via the Menu button; iOS needs a visible touch close so playing
        // music (which suppresses the auto-dismiss-on-stop) is never a dead-end.
        .overlay(alignment: .topLeading) {
            Button {
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title2.weight(.semibold))
                    .padding(14)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        #endif
        // Foreground, the Siri Remote play/pause arrives as a UIPress on the responder chain, NOT via
        // MPRemoteCommandCenter (that fires only from Control Center / background). Handle it here.
        .onPlayPauseCommandCompat {
            LogTap.shared.note("[NowPlaying] onPlayPauseCommand (in-app remote button)")
            coordinator.togglePlayPause()
        }
        // Auto-dismiss when playback stops (queue cleared / video handoff)
        .onChange(of: coordinator.currentItem == nil) { _, stopped in
            if stopped { close() }
        }
        .onAppear {
            transportFocus = .playPause
            scheduleChromeHide()
        }
        // The timer must not outlive the view.
        .onDisappear {
            chromeHideTask?.cancel()
        }
        // Activity from the chrome's own controls: these keep the countdown alive while it is up, they
        // do NOT wake it. Waking is `NowPlayingWakeSink`'s job, for the reason its own doc gives.
        .onChange(of: transportFocus) { _, _ in noteChromeInteraction() }
        .onChange(of: queueFocus) { _, _ in noteChromeInteraction() }
        // Scrub focus catches ENTRY only; scrubProgress keeps a pan that continues on an already
        // focused scrubber counting for its whole duration.
        .onChange(of: coordinator.isScrubbing) { _, _ in noteChromeInteraction() }
        .onChange(of: coordinator.scrubProgress) { _, _ in noteChromeInteraction() }
        // Playback, not UI: a new track is news, and a pause raises the chrome the same way it raises the
        // video transport. These two are the only wakes that do not come through the sink.
        .onChange(of: coordinator.currentItem?.id) { _, _ in revealChrome() }
        .onChange(of: coordinator.isPlaying) { _, _ in revealChrome() }
    }

    // MARK: - Chrome auto-hide (Sodalite#110)

    /// The two-column layout needs a queue worth showing. Gating it on `queue.count > 1` also centers a
    /// SINGLE-track album with the auto-hide idle, which is deliberate: that album's right column was
    /// only ever the metadata over an empty list, and centering is the look this whole feature is after.
    private var showsQueueColumn: Bool {
        hasQueue && chromeRevealed
    }

    /// A queue worth showing, whether or not the chrome is up right now. It decides where the title
    /// block lives across the auto-hide, and with it whether the chrome needs a reserve behind it.
    private var hasQueue: Bool {
        coordinator.queue.count > 1
    }

    /// Activity reported by the chrome's OWN controls, which only restarts the countdown, never wakes.
    ///
    /// The distinction is load-bearing. Hiding the chrome deletes the views holding focus, and SwiftUI
    /// answers that by writing nil into their `@FocusState`, which is indistinguishable at the binding
    /// from the user moving focus. Waking on it meant the screen woke itself on the same runloop turn
    /// it hid. While the chrome is down, focus changes are OUR doing; the only input that counts then
    /// comes through `NowPlayingWakeSink`.
    private func noteChromeInteraction() {
        #if os(tvOS)
        guard chromeRevealed else { return }
        scheduleChromeHide()
        #endif
    }

    /// Bring the chrome back and restart the idle countdown. Cheap enough to call on every pan delta.
    private func revealChrome() {
        #if os(tvOS)
        if !chromeRevealed {
            withAnimation(Self.chromeSwap) { chromeRevealed = true }
            // The sink is on its way out; hand focus to something that exists on the other side.
            transportFocus = .playPause
        }
        scheduleChromeHide()
        #endif
    }

    /// tvOS only. iPhone never reaches the two-column layout at all, and on iPad the reveal side of the
    /// deal does not exist: there is no focus engine, so the only ways back would be tapping a transport
    /// button (which pauses) or dragging the scrubber (which seeks). Chrome that hides itself with no
    /// harmless way to bring it back is a trap, and the request is for Apple Music's tvOS behaviour.
    private func scheduleChromeHide() {
        #if os(tvOS)
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: TransportAutoHide.idleDelay)
            guard !Task.isCancelled else { return }
            hideChromeIfIdle()
        }
        #endif
    }

    private func hideChromeIfIdle() {
        guard TransportAutoHide.hides(isPlaying: coordinator.isPlaying) else { return }
        LogTap.shared.note("[NowPlaying] chrome auto-hidden after idle")
        withAnimation(Self.chromeSwap) { chromeRevealed = false }
    }

    // MARK: - Layout

    /// Compact (iPhone) stacks everything in one vertical scroll so nothing is cut off; the regular
    /// (tvOS / iPad) tier keeps the side-by-side cover + queue layout.
    @ViewBuilder
    private var contentLayout: some View {
        if hSizeClass == .compact {
            ScrollView {
                VStack(spacing: 28) {
                    albumCover
                    trackMetadata(centered: false)
                    progressRow
                    transportRow
                    queueList
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, contentHPadding)
                .padding(.vertical, contentVPadding)
            }
        } else {
            // The queue aligns to the cover, never the reverse: see `NowPlayingWideLayout`.
            NowPlayingWideLayout(spacing: NowPlayingMetrics.wideSpacing, showsQueue: showsQueueColumn) {
                VStack(spacing: NowPlayingMetrics.columnSpacing) {
                    albumCover
                    // Metadata belongs to whichever column is on screen. Centered it sits under the
                    // cover, Apple Music's arrangement; two-column it heads the queue, as before.
                    if !showsQueueColumn {
                        trackMetadata(centered: true)
                            .transition(.opacity)
                    }
                    // Removed, not faded: an invisible view keeps its focus AND its full height,
                    // which pushed the artwork off centre. `NowPlayingWakeSink` holds the focus in
                    // their place, and the branch below decides how much of the height is worth
                    // keeping.
                    if chromeRevealed {
                        VStack(spacing: NowPlayingMetrics.chromeSpacing) {
                            transportRow
                            progressRow
                        }
                        .transition(.opacity)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            chromeHeight = height
                        }
                    } else if !hasQueue && chromeHeight > 0 {
                        // Only where nothing arrives to take the chrome's place. With a queue, the
                        // title block moves into this column as the chrome leaves and fills the gap
                        // on its own (8pt of travel, 42 with a wrapped title); reserving half the
                        // chrome on top of that would push the artwork back up by another 56. A
                        // single-track album has no queue and no arriving title, so there the half
                        // height is what keeps the artwork from dropping 85pt (Sodalite#109).
                        Color.clear.frame(height: chromeHeight / 2)
                    }
                }
                .frame(width: showsQueueColumn
                       ? NowPlayingMetrics.wideColumnWidth
                       : NowPlayingMetrics.soloColumnWidth)
            } queue: {
                VStack(alignment: .leading, spacing: 28) {
                    trackMetadata(centered: false)
                        .padding(.horizontal, Self.focusOverhang)
                    ScrollView(.vertical, showsIndicators: false) {
                        queueList
                            .padding(.horizontal, Self.focusOverhang)
                    }
                }
            }
            .padding(.horizontal, contentHPadding)
            .padding(.vertical, contentVPadding)
            .animation(Self.chromeSwap, value: showsQueueColumn)
            .animation(Self.chromeSwap, value: chromeRevealed)
        }
    }

    private var isCompact: Bool { hSizeClass == .compact }

    private var coverSide: CGFloat { NowPlayingMetrics.coverSide(compact: isCompact) }

    private var contentHPadding: CGFloat { NowPlayingMetrics.contentHPadding(compact: isCompact) }

    private var contentVPadding: CGFloat { NowPlayingMetrics.contentVPadding(compact: isCompact) }

    // MARK: - Background art

    private var backgroundArt: some View {
        let coverURL = coordinator.currentItem.flatMap {
            dependencies.jellyfinImageService.musicCoverURL(for: $0, maxWidth: 400)
        }

        return AsyncCachedImage(url: coverURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.Theme.restFillFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .blur(radius: 80)
        .overlay(Color.black.opacity(0.65))
        .ignoresSafeArea()
    }

    // MARK: - Album cover

    private var albumCover: some View {
        let coverURL = coordinator.currentItem.flatMap {
            dependencies.jellyfinImageService.musicCoverURL(for: $0, maxWidth: 600)
        }

        return AsyncCachedImage(url: coverURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.Theme.restFill)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 72))
                        .foregroundStyle(.tertiary)
                )
        }
        .frame(width: coverSide, height: coverSide)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 16)
    }

    // MARK: - Track metadata

    private func trackMetadata(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: NowPlayingMetrics.metadataSpacing) {
            if let item = coordinator.currentItem {
                if let context = coordinator.contextTitle, !context.isEmpty {
                    Text(context)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)

                    Text(item.name)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)
                }

                if let artist = item.trackArtistLine, !artist.isEmpty {
                    Text(artist)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text(String(localized: "nowplaying.notplaying", defaultValue: "Nothing Playing"))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: NowPlayingMetrics.transportSpacing) {
            TransportIconButton(
                systemImage: "backward.fill",
                focusKey: TransportButton.previous,
                transportFocus: $transportFocus,
                isDisabled: !coordinator.hasPrevious
            ) {
                noteChromeInteraction()
                coordinator.previous()
            }

            // Default focus, set via .onAppear in body.
            TransportIconButton(
                systemImage: coordinator.isPlaying ? "pause.fill" : "play.fill",
                focusKey: TransportButton.playPause,
                transportFocus: $transportFocus,
                isLarge: true
            ) {
                noteChromeInteraction()
                coordinator.togglePlayPause()
            }

            TransportIconButton(
                systemImage: "forward.fill",
                focusKey: TransportButton.next,
                transportFocus: $transportFocus,
                isDisabled: !coordinator.hasNext
            ) {
                noteChromeInteraction()
                coordinator.next()
            }
        }
    }

    // MARK: - Progress row / scrubber

    private var progressRow: some View {
        // Scrub FOCUS lives inside ScrubBar (the UIKit input layer reports it there); the pan itself
        // reaches the parent as scrubProgress. Both have to count as activity.
        ScrubBar(coordinator: coordinator, onFocusChange: { _ in noteChromeInteraction() })
    }

    // MARK: - Queue list

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if coordinator.queue.count > 1 {
                Text(String(localized: "nowplaying.queue.title", defaultValue: "Queue"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    ForEach(Array(coordinator.queue.enumerated()), id: \.element.id) { index, track in
                        QueueRow(
                            track: track,
                            isCurrent: index == coordinator.currentIndex,
                            isPlaying: coordinator.isPlaying,
                            queueFocus: $queueFocus,
                            onSelect: {
                                noteChromeInteraction()
                                // Switch within the same queue, keeping the album/playlist context.
                                coordinator.skip(toQueueIndex: index)
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Transport button focus enum

private enum TransportButton: Hashable {
    case previous
    case playPause
    case next
}

// MARK: - TransportIconButton

private struct TransportIconButton: View {
    let systemImage: String
    let focusKey: TransportButton
    @FocusState.Binding var transportFocus: TransportButton?
    var isLarge: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    /// The primary control needs the accent's ROLES, which the environment `.tint` cannot hand out:
    /// it is an opaque ShapeStyle. The cover is a plain SwiftUI presentation, so the key propagates.
    @Environment(\.appearanceTheme) private var appearanceTheme

    private var isFocused: Bool { transportFocus == focusKey }

    /// Play/Pause is accent-filled at all times (Sodalite#112), so focus cannot be the difference
    /// between filled and unfilled. It brightens the fill to the accent itself from a darker resting
    /// shade instead, and the whole colour decision stays in `AccentPalette`.
    ///
    /// On iOS the darker shade would be the ONLY state a user ever sees, since there is no focus
    /// engine to lift it, so the fill stays the accent there.
    private var primaryFill: Color {
        #if os(tvOS)
        return isFocused
            ? appearanceTheme.palette.control.color
            : appearanceTheme.palette.restingControl.color
        #else
        return appearanceTheme.palette.control.color
        #endif
    }

    var body: some View {
        // tvOS scales .title/.title2 to ~76/~57pt, so the glyph filled the frame and the focus circle
        // cut across it; fixed sizes clearly smaller than the circle keep the tint ring around the icon.
        let size: CGFloat = isLarge ? NowPlayingMetrics.transportPrimary : NowPlayingMetrics.transportSecondary
        let iconFont: Font = .system(size: isLarge ? 34 : 25, weight: .semibold)

        // .focusable + stableTap, NOT a Button: a tvOS Button (even .plain) paints the system white
        // focus card; our focus look is the tinted circle fill + stroke below.
        Image(systemName: systemImage)
            .font(iconFont)
            // The glyph sits on the accent, so it takes the accent's own foreground; white is
            // legible on thirteen of the twenty-three presets and no more (Sodalite#111).
            .foregroundStyle(isLarge
                ? AnyShapeStyle(appearanceTheme.palette.foreground.color)
                : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(isLarge
                        ? AnyShapeStyle(primaryFill)
                        : AnyShapeStyle(Color.white.opacity(isFocused ? 0.18 : 0.07)))
            )
            .overlay(
                // Previous/Next keep the outline-on-focus look; the filled primary would only get a
                // ring in its own colour, which is invisible against its own fill.
                Circle()
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused && !isLarge ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            // Second half of the primary's focus lift, and the half that carries the LIGHT accents:
            // their fill is bright enough that the brightness step alone is the subtler cue, while a
            // black drop shadow does nothing for them on a near-black backdrop.
            .shadow(
                color: appearanceTheme.palette.control.color
                    .opacity(isLarge && isFocused ? 0.55 : 0),
                radius: 22
            )
            .shadow(
                color: .black.opacity(isFocused ? 0.3 : 0),
                radius: 10,
                y: 4
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable(!isDisabled)
            .focused($transportFocus, equals: focusKey)
            .stableTap(isFocused: isFocused) {
                action()
            }
            .opacity(isDisabled ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isDisabled)
    }
}

// MARK: - ScrubBar

/// The fullscreen player's progress bar; drawn here from coordinator scrub state, with a focusable
/// UIKit overlay (`MusicScrubberInput`) owning gestures so it matches the video player.
private struct ScrubBar: View {
    let coordinator: MusicPlaybackCoordinator
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var isFocused = false

    private var fraction: CGFloat { CGFloat(coordinator.displayProgress) }
    private var scrubbing: Bool { coordinator.isScrubbing }
    private var barHeight: CGFloat { scrubbing ? 10 : (isFocused ? 7 : 5) }

    /// tvOS shows the knob only when focused/scrubbing (the focus ring implies interactivity); iOS has no focus
    /// engine, so show it always to signal the bar is draggable, matching the video player's touch scrubber.
    private var showKnob: Bool {
        #if os(iOS)
        return true
        #else
        return isFocused || scrubbing
        #endif
    }

    var body: some View {
        VStack(spacing: NowPlayingMetrics.scrubLabelSpacing) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: barHeight)

                    Capsule()
                        .fill(scrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                        .frame(width: geo.size.width * fraction, height: barHeight)

                    if showKnob {
                        let knob: CGFloat = scrubbing ? 24 : 16
                        Circle()
                            .fill(scrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                            .frame(width: knob, height: knob)
                            .offset(x: geo.size.width * fraction - knob / 2)
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                #if os(iOS)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            coordinator.scrubBegan()
                            coordinator.scrub(toFraction: Double(max(0, min(1, value.location.x / max(geo.size.width, 1)))))
                        }
                        .onEnded { _ in coordinator.commitScrub() }
                )
                #endif
            }
            .frame(height: NowPlayingMetrics.scrubTrackHeight)

            HStack {
                Text(MusicTimeFormatter.string(coordinator.displayTime))
                    .font(.caption)
                    .foregroundStyle(scrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                    .monospacedDigit()

                Spacer()

                Text(MusicTimeFormatter.string(coordinator.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        #if os(tvOS)
        .overlay(
            MusicScrubberInput(coordinator: coordinator, isFocused: $isFocused)
        )
        #endif
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: scrubbing)
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
    }
}

// MARK: - QueueRow

private struct QueueRow: View {
    let track: JellyfinItem
    let isCurrent: Bool
    let isPlaying: Bool
    @FocusState.Binding var queueFocus: String?
    let onSelect: () -> Void

    private var focused: Bool { queueFocus == track.id }

    var body: some View {
        HStack(spacing: 16) {
            if isCurrent {
                NowPlayingWaveIcon(isPlaying: isPlaying, font: .caption)
                    .frame(width: 24, alignment: .center)
            } else {
                Text(track.indexNumber.map { String($0) } ?? "")
                    .font(.caption)
                    .foregroundStyle(focused ? .white : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 24, alignment: .trailing)
            }

            QueueTrackName(
                name: track.name,
                isCurrent: isCurrent,
                focused: focused
            )

            if let ticks = track.runTimeTicks,
               let formatted = ResumeTimeFormatter.format(ticks: ticks) {
                Text(formatted)
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent
                      ? Color.white.opacity(focused ? 0.18 : 0.1)
                      : Color.white.opacity(focused ? 0.14 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 10, y: 4)
        .focusable(true)
        .focused($queueFocus, equals: track.id)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .stableTap(isFocused: focused) {
            onSelect()
        }
    }
}

// MARK: - QueueTrackName

/// Separate view to apply `.tint` for the current track without mixing TintShapeStyle and Color in a ternary.
private struct QueueTrackName: View {
    let name: String
    let isCurrent: Bool
    let focused: Bool

    var body: some View {
        Text(name)
            .font(.callout)
            .fontWeight(isCurrent ? .semibold : .regular)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(QueueTrackNameStyle(isCurrent: isCurrent, focused: focused))
    }
}

private struct QueueTrackNameStyle: ViewModifier {
    let isCurrent: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        if isCurrent {
            content.foregroundStyle(.tint)
        } else {
            content.foregroundStyle(focused ? Color.white : Color.primary)
        }
    }
}

// MARK: - FullBleedSafeArea

/// Applies `.ignoresSafeArea()` only when active, so the regular tier keeps its full-bleed overscan
/// layout while compact lets the scroll content sit inside the safe area.
private struct FullBleedSafeArea: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}
