import SwiftUI
import AetherEngine

// MARK: - Overlay View (display-only SwiftUI)

/// Display-only overlay mounted over the AVPlayerViewController by `PlayerHostController`; all state reads from `PlayerViewModel`, input handled by the UIKit host (hence `.allowsHitTesting(false)` where it would otherwise capture focus).
struct PlayerOverlayView: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    /// Literal player tint (the host's `.tint(...)` value) passed explicitly because the subtitle-search overlay needs a concrete `Color` for focused-row fills, not just the environment tint.
    var tintColor: Color? = nil

    var body: some View {
        ZStack {
            #if os(iOS)
            // Bottom gesture layer: catches taps / swipes on the empty video area; the controls and
            // buttons render above it and win their own hits. Explicit fill: a plain UIView has no
            // intrinsic size and would otherwise collapse to 0x0 and receive no touches.
            // Removed entirely while the child lock is engaged so no swipe/tap reaches playback.
            if !viewModel.isInputLocked {
                PlayerGestureCatcher(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            #endif

            // Subtitle rendering (incl. the ~10 Hz subtitleTime clock) is observed inside SubtitleLayer,
            // not here, so this top-level overlay body does not re-evaluate its whole ZStack every tick
            // while subtitles are active. (perf: observation altitude)
            SubtitleLayer(viewModel: viewModel)

            if viewModel.isLoading {
                // Inner ZStack + whole-stack ignoresSafeArea so the spinner shares the backdrop's coord space; centering on Color.black's layout bounds (which respect safe-area) drifted the spinner top-half when an outgoing next-episode card shifted the parent's insets.
                ZStack {
                    Color.black
                    ProgressView()
                        // ProgressView doesn't reliably inherit the overlay's `.tint(...)` on tvOS (falls back to white); set it explicitly.
                        .tint(tintColor ?? .accentColor)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            // Sits above the spinner layer and above the running picture alike: the reader is fighting the
            // source either way, and a stall that leaves the picture running no longer raises a spinner at
            // all, so this is the only thing that explains the freeze the viewer is about to see.
            if viewModel.showsConnectionNotice, viewModel.errorMessage == nil {
                VStack {
                    ConnectionNoticeChip()
                        .padding(.top, 40)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if let error = viewModel.errorMessage {
                ZStack {
                    Color.black
                    VStack(spacing: 20) {
                        Image(systemName: viewModel.errorIcon ?? "exclamationmark.triangle")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        if let title = viewModel.errorTitle {
                            Text(title)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 720)
                        HStack(spacing: 20) {
                            // Only a confirmed server outage offers this: the server is expected back and
                            // nothing about the item changed, so one press resumes where it stopped.
                            if viewModel.canRetryAfterOutage {
                                ErrorActionButton(
                                    titleKey: "player.error.retry",
                                    isHighlighted: viewModel.errorFocus == .retry,
                                    action: { viewModel.retryAfterOutage() }
                                )
                            }
                            ErrorActionButton(
                                titleKey: "player.error.back",
                                isHighlighted: viewModel.errorFocus == .back,
                                action: onDismiss
                            )
                        }
                        .padding(.top, 8)
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if viewModel.showControls && !viewModel.isLoading && viewModel.errorMessage == nil && !viewModel.isInputLocked {
                // iOS swipe hints live INSIDE controlsOverlay's absolute-geometry wrapper (Sodalite#15 portrait clip).
                controlsOverlay
            }

            // Stats-for-nerds panel mounted above the controls overlay so it stays readable when the transport's auto-hide fires.
            if viewModel.showStatsOverlay && viewModel.errorMessage == nil {
                StatsOverlayView(
                    player: viewModel.player,
                    diagnostics: viewModel.player.diagnostics,
                    facts: viewModel.statsSourceFacts,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    scrollSectionIndex: viewModel.statsSectionIndex,
                    availableSections: viewModel.statsSectionAvailability,
                    isLiveSession: viewModel.isLiveSession,
                    liveChannel: viewModel.liveChannel,
                    liveRoute: viewModel.liveRoute,
                    liveStreamID: viewModel.activeLiveStreamID,
                    playMethod: viewModel.activePlayMethod,
                    onClose: { viewModel.showStatsOverlay = false }
                )
            }

            topRightInfoColumn

            // Floating skip hint (intro or recap), only while controls are hidden; once they open, the skip action is a focusable button inside TransportBar instead.
            if let skipSegment = viewModel.activeSkipSegment,
               !viewModel.showControls,
               viewModel.errorMessage == nil,
               !viewModel.showNextEpisodeOverlay {
                segmentSkipOverlay(label: skipSegment.kind.buttonLabel)
            }

            // Floating next-episode prompt. On tvOS it follows the skip pill exactly: hidden once the
            // transport opens, where the same action is a focusable TransportBar button instead
            // (Sodalite#103). Touch has no focus handover, so it stays and lifts clear of the controls.
            if viewModel.showNextEpisodeOverlay,
               let next = viewModel.nextEpisode,
               showsFloatingNextEpisodePrompt {
                nextEpisodeOverlay(next)
            }

            #if os(iOS)
            // Transient brightness/volume/skip HUD, centered above the controls (kept mounted so the
            // opacity fade animates cleanly).
            PlayerHUD(kind: viewModel.hudKind ?? viewModel.lastHudKind, level: viewModel.hudLevel)
                .opacity(viewModel.hudKind == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: viewModel.hudKind)
                .allowsHitTesting(false)
                .zIndex(60)
            #endif

            // Subtitle search overlay (Feature #4); uses literal player tint so focused rows fill with the server accent, not white.
            if viewModel.subtitleSearchVisible {
                SubtitleSearchView(
                    viewModel: viewModel,
                    tint: tintColor ?? .accentColor
                )
                .transition(.opacity)
                .zIndex(50)
            }

            if viewModel.isSubtitleDeletePromptVisible {
                SubtitleDeletePromptView(
                    viewModel: viewModel,
                    tint: tintColor ?? .accentColor
                )
                .transition(.opacity)
                .zIndex(51)
            }

            #if os(iOS)
            // Child lock: top of the z-order so it swallows every gesture; the gesture catcher and
            // controls are already removed above, and pickers/stats/subtitle-search can't be opened
            // while locked, so nothing below can react. Subtitles keep rendering (kid keeps watching).
            if viewModel.isInputLocked {
                PlayerLockOverlay(viewModel: viewModel, tint: tintColor ?? .accentColor)
                    .transition(.opacity)
                    .zIndex(100)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showsConnectionNotice)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showNextEpisodeOverlay)
        .animation(.easeInOut(duration: 0.25), value: viewModel.activeSkipSegment)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showStatsOverlay)
        .animation(.easeInOut(duration: 0.3), value: viewModel.subtitleSearchVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isSubtitleDeletePromptVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isInputLocked)
        #if os(iOS)
        // External-subtitle delete (Feature #4 on touch): confirmation dialog + error alert for the
        // trash button in PlayerTouchControls' subtitle picker. Hoisted OUT of the touch-controls
        // subtree because presentation modifiers are safe-area-aware and re-apply the corrupt portrait
        // insets AVKit's hosting serves for the first seconds after open/rotation (Sodalite#15
        // portrait clip); on the root they can't displace the controls. State machine lives in the VM.
        .confirmationDialog(
            Text("player.subtitle.delete.title"),
            isPresented: Binding(
                get: { if case .confirm = viewModel.subtitleDeleteState { return true } else { return false } },
                set: { presented in
                    if !presented, case .confirm = viewModel.subtitleDeleteState {
                        viewModel.subtitleDeletePromptDismiss()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "player.subtitle.delete.confirm", defaultValue: "Delete"), role: .destructive) {
                viewModel.subtitleDeletePromptConfirmDelete()
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.subtitleDeletePromptDismiss()
            }
        }
        .alert(
            subtitleDeleteErrorText,
            isPresented: Binding(
                get: { if case .error = viewModel.subtitleDeleteState { return true } else { return false } },
                set: { presented in
                    if !presented { viewModel.subtitleDeletePromptDismiss() }
                }
            )
        ) {
            Button(String(localized: "common.ok", defaultValue: "OK")) {
                viewModel.subtitleDeletePromptDismiss()
            }
        }
        #endif
    }

    #if os(iOS)
    private var subtitleDeleteErrorText: String {
        if case .error(let message) = viewModel.subtitleDeleteState { return message }
        return ""
    }
    #endif

    #if os(iOS)
    private var swipeHintsOverlay: some View {
        swipeHintsRow
            // FIXED width instead of horizontal padding, same rationale as PlayerTouchControls'
            // fixed-width chrome (Sodalite#15 portrait clip): the corrupt safe rect balloons flexible
            // children symmetrically, a UIKit-derived fixed width stays centered and correct.
            .frame(width: PlayerTouchControls.chromeContentWidth(margin: 20))
            // Visual only; the actual swipe is handled by the gesture catcher underneath.
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var swipeHintsRow: some View {
        HStack {
            swipeHint(icon: "sun.max.fill")
            Spacer()
            swipeHint(icon: "speaker.wave.2.fill")
        }
    }

    private func swipeHint(icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up").font(.caption2.weight(.semibold))
            Image(systemName: icon).font(.subheadline)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.vertical, 9)
        .padding(.horizontal, 7)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .opacity(0.55)
        )
    }
    #endif

    private func segmentSkipOverlay(label: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                // Anchor from PlayerActionPill, the same one the next-episode prompt positions to.
                skipSegmentHint(label: label)
                    .padding(.trailing, PlayerPillMetrics.current.marginX)
                    .padding(.bottom, PlayerPillMetrics.current.marginY)
            }
        }
        // ignoresSafeArea pins the hint to the true screen bottom: alpha=0 AVKit chrome (kept for the CC +10s handler via playbackControlsIncludeTransportBar) still widens contentOverlayView's bottom safe-area inset, which would shift a Spacer-anchored hint mid-screen at session start.
        .ignoresSafeArea()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }

    private func skipSegmentHint(label: String) -> some View {
        // Chrome and geometry come from PlayerActionPill, shared with the next-episode prompt that
        // lands in this same corner seconds later (Sodalite#103).
        let content = PlayerPillLabel(title: label) {
            Image(systemName: "forward.end.fill")
                .font(PlayerPillMetrics.current.labelFont)
        }
        .playerGlassPill()
        #if os(iOS)
        return Button { viewModel.skipActiveSegment() } label: { content }.buttonStyle(.plain)
        #else
        return content
        #endif
    }

    /// Whether the floating prompt draws at all. tvOS hands it to TransportBar while the transport
    /// is open, because that is where Select goes: with controls up, `PlayerHostController` routes
    /// the press to the focused control, so a floating pill there would promise a press it cannot take.
    private var showsFloatingNextEpisodePrompt: Bool {
        #if os(tvOS)
        return !viewModel.showControls
        #else
        return true
        #endif
    }

    private func nextEpisodeOverlay(_ episode: JellyfinItem) -> some View {
        // Absolute scene-screen `.position(x:,y:)` instead of frame/alignment anchors: at end-of-playback playNextEpisode tears down AVKit chrome, collapsing the SwiftUI parent's frame for ~100 ms, so any alignment-based anchor recomputes against the shrunken parent and drifts the prompt mid-screen. Scene-derived screen (not deprecated UIScreen.main); 1080p fallback is the impossible no-scene case.
        let screen = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 1920, height: 1080)
        let metrics = PlayerPillMetrics.current
        let marginX = metrics.marginX
        #if os(iOS)
        // The skip pill's anchor, except that the prompt stays put with the touch controls up, so it
        // lifts clear of them instead of hiding the way the skip pill does.
        let marginY: CGFloat = viewModel.showControls ? 150 : metrics.marginY
        #else
        // On tvOS this only renders with the transport hidden, so there is no open-transport margin
        // to dodge; the prompt is a TransportBar button then.
        let marginY = metrics.marginY
        #endif
        // A portrait phone has less width than the stack wants; the pill hugs its label either way,
        // the frame only bounds the metadata line's truncation.
        let width = min(metrics.stackWidth, screen.width - marginX * 2)
        return nextEpisodePillButton(for: episode, width: width, screen: screen, marginX: marginX, metrics: metrics)
            .position(
                x: screen.width - width / 2 - marginX,
                y: screen.height - metrics.stackHeight / 2 - marginY
            )
            .ignoresSafeArea()
            // Asymmetric: slide in from trailing, fade-only on removal. Symmetric `.move(edge: .trailing)` removal composed with the end-of-playback parent reflow and exposed the drift-to-middle symptom; fade has no spatial component to disrupt.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            ))
    }

    @ViewBuilder
    private func nextEpisodePillButton(for episode: JellyfinItem, width: CGFloat, screen: CGSize, marginX: CGFloat, metrics: PlayerPillMetrics) -> some View {
        let pill = NextEpisodePill(
            title: nextEpisodeLabel(for: episode),
            metadata: nextEpisodeMetadata(for: episode),
            countdownProgress: NextEpisodeCountdown.ringProgress(
                remaining: viewModel.isCountdownActive ? viewModel.nextEpisodeCountdown : 0,
                total: viewModel.nextEpisodeCountdownTotal),
            width: width,
            // The line may grow left across the whole usable width before it ever truncates.
            metadataMaxWidth: max(width, screen.width - marginX * 2),
            metrics: metrics
        )
        #if os(iOS)
        // Tappable on touch; tvOS commits via the Select press machine.
        Button { Task { await viewModel.playNextEpisode() } } label: { pill }
            .buttonStyle(.plain)
        #else
        pill
        #endif
    }

    /// Episodes show "Next Episode"; a movie reached via a shuffle queue shows "Up Next".
    private func nextEpisodeLabel(for episode: JellyfinItem) -> String {
        episode.type == .episode
            ? String(localized: "player.nextEpisode", defaultValue: "Next Episode")
            : String(localized: "player.upNext", defaultValue: "Up Next")
    }

    /// The line above the pill. Kept out of the pill so the pill stays one width per tier: in the
    /// label this would be the only part that varies per episode, and a long title runs to twice the
    /// width of the card this replaces. Naturally just the title for a movie, which has no S/E token.
    private func nextEpisodeMetadata(for episode: JellyfinItem) -> String? {
        let token = EpisodeMetadataFormatter.seasonEpisode(
            season: episode.parentIndexNumber, episode: episode.indexNumber)
        let name = episode.name
        if name.isEmpty { return token.isEmpty ? nil : token }
        return token.isEmpty ? name : "\(token) · \(name)"
    }

    /// Build episode thumbnail URL directly from item data
    /// (avoids needing JellyfinImageService in the player).
    private func episodeThumbnailURL(for item: JellyfinItem) -> URL? {
        guard let baseURL = viewModel.playbackService.baseURL else { return nil }
        if let tag = item.imageTags?.primary {
            return URL(string: "\(baseURL)/Items/\(item.id)/Images/Primary?tag=\(tag)&maxWidth=640&quality=80")
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return URL(string: "\(baseURL)/Items/\(item.id)/Images/Backdrop?tag=\(tag)&maxWidth=640&quality=80")
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return URL(string: "\(baseURL)/Items/\(seriesId)/Images/Backdrop?tag=\(tag)&maxWidth=640&quality=80")
        }
        return nil
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        #if os(iOS)
        // Absolute-geometry chrome mount (same pattern as nextEpisodeOverlay's scene-screen position):
        // inside AVKit, the SwiftUI hosting pipeline serves corrupt NEGATIVE horizontal safe-area
        // insets in portrait for the first seconds after open and after each rotation, while AVKit's
        // invisible chrome counts as visible (SDR content only; HDR's display-mode switch resets it
        // during load). Every public UIKit inset API reads clean meanwhile, and the corrupt values
        // re-apply at every safe-area-aware SwiftUI node, so the chrome subtree avoids them entirely:
        // the GeometryReader measures the (symmetric) corrupt region in global space, a fixed
        // window-sized frame is pinned back over the real screen, and the window's safe-area insets
        // are applied as PLAIN padding. Nothing inside this wrapper may use .ignoresSafeArea or
        // .safeAreaPadding, or the corruption re-enters (measured; see project memory).
        GeometryReader { geo in
            let allotted = geo.frame(in: .global)
            let (screen, insets) = Self.windowGeometry(fallback: geo.size)
            let insetPadding = EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
            ZStack {
                // Bottom scrim at the true screen bottom; lives here (not in PlayerTouchControls) so
                // it can full-bleed without .ignoresSafeArea. Decorative only: in landscape it covers
                // the vertical center where the brightness/volume swipe happens, so it must not
                // capture touches (they fall through to the gesture catcher below).
                VStack {
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 260)
                }
                .allowsHitTesting(false)

                PlayerTouchControls(
                    viewModel: viewModel,
                    onDismiss: onDismiss,
                    tintColor: tintColor,
                    episodeImageURL: { episodeThumbnailURL(for: $0) },
                    chapterThumbnail: { await viewModel.chapterThumbnail(forIndex: $0) }
                )
                .padding(insetPadding)

                // Subtle edge affordances: a vertical swipe on the left adjusts brightness, on the right volume.
                if !viewModel.isScrubbing {
                    swipeHintsOverlay
                        .padding(insetPadding)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .position(x: screen.width / 2 - allotted.minX, y: screen.height / 2 - allotted.minY)
        }
        #else
        tvOSControlsOverlay
        #endif
    }

    #if os(iOS)
    /// The window's UIKit-truth geometry; the hosting pipeline's safe area is untrustworthy here.
    /// Tolerates scene/key churn during the modal transition (scene order is undefined and keyWindow
    /// can be transiently nil). Shared with the stats panel, which mounts the same absolute wrapper.
    static func windowGeometry(fallback: CGSize) -> (CGRect, UIEdgeInsets) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first }
                .first
        guard let window else { return (CGRect(origin: .zero, size: fallback), .zero) }
        return (window.bounds, window.safeAreaInsets)
    }
    #endif

    private var tvOSControlsOverlay: some View {
        // Pin to scene-screen bounds (same fix as the next-episode card): an audio-track switch reloads AVKit and transiently collapses its container frame, so a Spacer/alignment-anchored controls block jumps up while fading. Absolute screen-sized frame + center position removes the dependency on the churning AVKit parent.
        let screen = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 1920, height: 1080)
        return ZStack {
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 300)
            }
            .ignoresSafeArea()

            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 200)
                Spacer()
            }
            .ignoresSafeArea()

            // Title (top left); HDR + Speed badges live in topRightInfoColumn so the speed badge can persist after the transport hides.
            VStack {
                HStack(alignment: .top) {
                    PlayerTitleOverlay(item: viewModel.item)
                    Spacer()
                }
                Spacer()
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                if viewModel.isLiveSession {
                    LiveTransportBar(viewModel: viewModel)
                } else {
                TransportBar(
                    // Clock values (progress/currentTime/remainingTime/isScrubbing/scrubTime) are read
                    // inside TransportBar from this view model, so they don't re-evaluate the parent body.
                    viewModel: viewModel,
                    audioTracks: viewModel.displayAudioTracks,
                    subtitleStreams: viewModel.displaySubtitleStreams,
                    activeAudioIndex: viewModel.activeAudioIndex,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    activeSecondarySubtitleIndex: viewModel.activeSecondarySubtitleIndex,
                    secondarySubtitleCandidates: viewModel.secondarySubtitleCandidates,
                    supportsSubtitleSearch: viewModel.supportsSubtitleSearch,
                    activeSpeedIndex: viewModel.activeSpeedIndex,
                    controlsFocus: viewModel.controlsFocus,
                    trackDropdown: viewModel.trackDropdown,
                    skipSegmentLabel: viewModel.activeSkipSegment?.kind.buttonLabel,
                    nextEpisodeLabel: viewModel.showNextEpisodeOverlay
                        ? viewModel.nextEpisode.map { nextEpisodeLabel(for: $0) } : nil,
                    nextEpisodeCountdownProgress: NextEpisodeCountdown.ringProgress(
                        remaining: viewModel.isCountdownActive ? viewModel.nextEpisodeCountdown : 0,
                        total: viewModel.nextEpisodeCountdownTotal),
                    seasonEpisodes: viewModel.seasonEpisodes,
                    activeEpisodeID: viewModel.item.id,
                    episodeImageURL: { episodeThumbnailURL(for: $0) },
                    chapters: viewModel.chapters,
                    durationSeconds: viewModel.player.duration,
                    chapterThumbnail: { await viewModel.chapterThumbnail(forIndex: $0) },
                    pictureMode: viewModel.pictureMode,
                    showsInfoButton: viewModel.preferences.showStatsForNerds,
                    showsPiPButton: viewModel.isPiPAvailable,
                    isPiPEnabled: viewModel.isPiPPossible,
                    isStatsOverlayOpen: viewModel.showStatsOverlay,
                    previewImage: viewModel.scrubPreview.previewImage
                )
                }
            }
            .ignoresSafeArea()
        }
        .frame(width: screen.width, height: screen.height)
        .position(x: screen.width / 2, y: screen.height / 2)
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

// MARK: - Top-Right Info Column

private extension PlayerOverlayView {
    /// Top-right informational badges: the format badge follows transport visibility (matches Apple TV's player) on tvOS only, on iOS it sits inside the touch top bar instead; speed badge persists whenever rate != 1.0x so a user who set 1.5x then hid the transport isn't silently at the wrong speed.
    var topRightInfoColumn: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    #if os(tvOS)
                    if viewModel.showControls && viewModel.videoFormat != .sdr {
                        VideoFormatBadge(format: viewModel.videoFormat)
                    }
                    #endif
                    if PlayerViewModel.speedOptions.indices.contains(viewModel.activeSpeedIndex),
                       PlayerViewModel.speedOptions[viewModel.activeSpeedIndex] != 1.0 {
                        SpeedBadge(index: viewModel.activeSpeedIndex)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 68)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSpeedIndex)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.2), value: viewModel.videoFormat)
        .allowsHitTesting(false)
    }
}

// MARK: - Speed Badge

private struct SpeedBadge: View {
    let index: Int

    var body: some View {
        Text(TransportBar.speedLabel(for: index))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }
}

// MARK: - Video Format Badge

struct VideoFormatBadge: View {
    let format: VideoFormat
    /// Compact pill for the iOS touch top bar (flush with its 44pt buttons); full size for the tvOS top-right column.
    var compact = false

    var body: some View {
        Text(label)
            .font(.system(size: compact ? 13 : 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }

    private var label: String {
        switch format {
        case .sdr:          return "SDR"
        case .hdr10:        return "HDR10"
        case .hdr10Plus:    return "HDR10+"
        case .dolbyVision:  return "Dolby Vision"
        case .hlg:          return "HLG"
        }
    }
}

/// Confines the subtitle inputs, including the ~10 Hz `subtitleTime` clock, to their own leaf body so
/// PlayerOverlayView (the hosting root) does not re-evaluate its entire ZStack on every clock tick while
/// subtitles are active. When no cues or ASS renderer are present the body reads no clock at all, so idle
/// playback with subtitles off establishes no per-tick dependency. (perf: observation altitude)
private struct SubtitleLayer: View {
    let viewModel: PlayerViewModel

    var body: some View {
        // AE#227: while the native rendition renders the subtitles (PiP, AirPlay, external display), AVKit
        // owns them; drawing here as well double-draws on the device and on the way back from the route.
        // Keep the styled ASS layer mounted even while the cue array is momentarily empty (seek resets); libass already holds the assembled script.
        if !viewModel.nativeSubtitleRenderingActive,
           viewModel.assRenderer != nil || !viewModel.subtitleCues.isEmpty || !viewModel.secondarySubtitleCues.isEmpty {
            SubtitleOverlayView(
                cues: viewModel.subtitleCues,
                currentTime: viewModel.subtitleTime,
                maxCueDuration: viewModel.subtitleMaxCueDuration,
                secondaryCues: viewModel.secondarySubtitleCues,
                secondaryMaxCueDuration: viewModel.secondarySubtitleMaxCueDuration,
                fontSize: viewModel.preferences.subtitleFontSize,
                textColor: viewModel.preferences.subtitleColor,
                background: viewModel.preferences.subtitleBackground,
                delaySeconds: viewModel.preferences.subtitleDelaySeconds,
                verticalPosition: viewModel.preferences.subtitleVerticalPosition,
                font: viewModel.preferences.subtitleFont,
                weight: viewModel.preferences.subtitleWeight,
                controlsVisible: viewModel.showControls,
                assRenderer: viewModel.assRenderer,
                assReloadSignal: viewModel.assReloadSignal,
                activeSubtitleCodec: viewModel.activeSubtitleCodec,
                hasSecondaryTrack: viewModel.activeSecondarySubtitleIndex != nil,
                videoSize: viewModel.videoSize,
                pictureMode: viewModel.pictureMode
            )
        }
    }
}

/// The "source is not delivering" pill. Deliberately small and non-modal: on the loopback path the picture
/// usually keeps running out of the segment cache while the reader reconnects, and covering that with a
/// black spinner is the bug this chip replaces.
private struct ConnectionNoticeChip: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
            Text("player.notice.reconnecting")
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.65), in: Capsule())
    }
}

/// One error-screen action.
///
/// On tvOS this deliberately is NOT a `Button`: the player hosts this overlay with
/// `isUserInteractionEnabled = false` and drives input through UIKit press handlers, so a Button here
/// renders but can never focus or fire (which is what left both of these buttons dead until now). The
/// highlight comes from `PlayerViewModel.errorFocus`, the press from `PlayerHostController`. On iOS the
/// overlay is touch-interactive, so there it is an ordinary button.
private struct ErrorActionButton: View {
    let titleKey: LocalizedStringKey
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        label
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(isHighlighted ? 0.15 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isHighlighted ? 1 : 0)
            )
            .scaleEffect(isHighlighted ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        #else
        Button(action: action) { label }
            .buttonStyle(SettingsTileButtonStyle())
        #endif
    }

    private var label: some View {
        Text(titleKey)
            .font(.body)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
    }
}
