import AetherEngine
import SwiftUI

/// DVR transport for live playback: scrubber over the engine's moving seekable
/// window, live-edge marker, position/LIVE label, and a "Return to Live" pill
/// focusable via Up (PlayerHostController routes `.returnToLiveButton` Select
/// to returnToLiveEdge); scrubbing to the right edge also snaps to live
/// (commitLiveScrub at >= 0.99).
struct LiveTransportBar: View {
    @Bindable var viewModel: PlayerViewModel

    private var returnToLiveFocused: Bool {
        viewModel.controlsFocus == .returnToLiveButton
    }

    private var pipFocused: Bool {
        viewModel.controlsFocus == .pipButton
    }

    private var subtitleFocused: Bool {
        viewModel.controlsFocus == .subtitleButton
    }

    private var audioFocused: Bool {
        viewModel.controlsFocus == .audioButton
    }

    private var infoFocused: Bool {
        viewModel.controlsFocus == .infoButton
    }

    /// TransportBar keeps its own `isSubtitleDropdownOpen` private to that file, so derive it rather
    /// than widening the view model with a second spelling of the same state.
    private var isSubtitleDropdownOpen: Bool {
        if case .subtitle = viewModel.trackDropdown { return true }
        return false
    }

    private var isAudioDropdownOpen: Bool {
        if case .audio = viewModel.trackDropdown { return true }
        return false
    }

    /// Same label the VOD bar shows on its audio chip: the active track, else the generic word.
    private var activeAudioLabel: String {
        guard let track = viewModel.displayAudioTracks
            .first(where: { $0.id == viewModel.activeAudioIndex }) else {
            return String(localized: "player.audio", defaultValue: "Audio")
        }
        return TrackDisplayFormatter.shortName(for: track)
    }

    /// Rows of the audio menu: every track the channel carries, in picker order. The highlight index
    /// is the host's (`moveDropdownHighlight` walks `displayAudioTracks`), so this maps the same list.
    private var audioDropdownItems: [DropdownItem] {
        guard case .audio(let highlighted) = viewModel.trackDropdown else { return [] }
        return viewModel.displayAudioTracks.enumerated().map { index, track in
            DropdownItem(title: TrackDisplayFormatter.audioDisplayName(for: track),
                         isActive: track.id == viewModel.activeAudioIndex,
                         isHighlighted: highlighted == index)
        }
    }

    /// Same rows the VOD bar shows, which on live means Off plus whatever the channel carries: no
    /// secondary track, no online search. The menu itself is the shared component, only the chip
    /// differs, because this bar speaks in capsules.
    /// Same label the VOD bar shows on its subtitle chip: the active track, else Off.
    private var activeSubtitleLabel: String {
        guard let idx = viewModel.activeSubtitleIndex,
              let stream = viewModel.displaySubtitleStreams.first(where: { $0.index == idx }) else {
            return String(localized: "player.subtitles.off", defaultValue: "Off")
        }
        return TrackDisplayFormatter.subtitleShortName(for: stream)
    }

    /// Whether a real subtitle stream is on. Mirrors `activeSubtitleLabel`'s own guard so the chip
    /// never pins a label that reads "Off".
    private var hasActiveSubtitle: Bool {
        guard let idx = viewModel.activeSubtitleIndex else { return false }
        return viewModel.displaySubtitleStreams.contains(where: { $0.index == idx })
    }

    private var subtitleDropdownItems: [DropdownItem] {
        guard case .subtitle(let highlighted) = viewModel.trackDropdown else { return [] }
        return viewModel.subtitleMenuRows.enumerated().compactMap { index, row in
            switch row {
            case .off:
                return DropdownItem(title: String(localized: "player.subtitles.off", defaultValue: "Off"),
                                    isActive: viewModel.activeSubtitleIndex == nil,
                                    isHighlighted: highlighted == index)
            case .track(let streamIndex):
                guard let stream = viewModel.displaySubtitleStreams
                    .first(where: { $0.index == streamIndex }) else { return nil }
                return DropdownItem(title: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                                    isActive: streamIndex == viewModel.activeSubtitleIndex,
                                    isHighlighted: highlighted == index)
            case .secondaryHeader, .searchOnline:
                return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.isScrubbing, let preview = viewModel.scrubPreview.previewImage {
                liveScrubPreviewArea(image: preview)
            }

            // .bottom, as in the VOD bar: an open menu grows its own column upward, and a centred
            // row would lift every sibling off the baseline to meet it.
            HStack(alignment: .bottom, spacing: 16) {
                if !viewModel.isPlaying {
                    PausedGlyph()
                        .font(.callout)
                }

                Text(positionLabel)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                if !viewModel.isAtLiveEdge {
                    TransportTrackLabel(
                        label: String(localized: "livetv.returnToLive", defaultValue: "Return to Live"),
                        icon: "forward.end.alt.fill",
                        showsLabel: true,
                        isFocused: returnToLiveFocused
                    )
                }

                if !viewModel.displayAudioTracks.isEmpty {
                    // Same gap and the same label rule as the VOD bar (#124): no off-state, so the
                    // chip stays a glyph until focus (or its open menu, which holds focus) asks.
                    VStack(spacing: 12) {
                        if isAudioDropdownOpen {
                            PlayerTrackDropdownList(items: audioDropdownItems)
                        }
                        TransportTrackLabel(
                            label: activeAudioLabel,
                            icon: "speaker.wave.2",
                            showsLabel: audioFocused,
                            isFocused: audioFocused
                        )
                    }
                }

                if !viewModel.displaySubtitleStreams.isEmpty {
                    VStack(spacing: 12) {
                        if isSubtitleDropdownOpen {
                            PlayerTrackDropdownList(items: subtitleDropdownItems)
                        }
                        TransportTrackLabel(
                            label: activeSubtitleLabel,
                            icon: "captions.bubble",
                            showsLabel: hasActiveSubtitle || subtitleFocused,
                            isFocused: subtitleFocused
                        )
                    }
                }

                if viewModel.isPiPAvailable {
                    TransportTrackLabel(
                        label: String(localized: "player.pip", defaultValue: "Picture in Picture"),
                        icon: "pip.enter",
                        showsLabel: false,
                        isFocused: pipFocused
                    )
                    .opacity(viewModel.isPiPPossible ? 1.0 : 0.4)
                }

                // The chip the VOD bar has always had. Without it the stats panel existed on a live channel
                // and had no way to be opened on tvOS, which is where a live route or a tuner id is worth
                // reading; the touch bar on iOS never gated it, so the two players disagreed.
                if viewModel.preferences.showStatsForNerds {
                    TransportTrackLabel(
                        label: String(localized: "player.stats", defaultValue: "Stats"),
                        icon: "info.circle",
                        showsLabel: false,
                        isFocused: infoFocused || viewModel.showStatsOverlay
                    )
                }

                liveBadge
            }
            // Same treatment as the VOD row, and for the same reason: a transaction (not
            // .animation(value:), which lags a frame so only the immediate neighbour glides) puts
            // menu open/close, label reveal, pill scale and sibling reflow on one curve.
            .transaction { txn in
                txn.animation = .smooth(duration: 0.32)
            }

            scrubber
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isScrubbing)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAtLiveEdge)
        .animation(.smooth(duration: 0.25), value: viewModel.isPlaying)
        .animation(.smooth(duration: 0.32), value: viewModel.controlsFocus)
        .animation(.smooth(duration: 0.32), value: viewModel.trackDropdown)
    }

    // MARK: - Live Badge

    /// "LIVE" pill: tinted at the edge, muted while behind live.
    private var liveBadge: some View {
        Text("livetv.liveBadge")
            .font(.caption.bold())
            .foregroundStyle(viewModel.isAtLiveEdge ? Color.white : .white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(viewModel.isAtLiveEdge ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.Theme.restFillStrong))
            )
    }

    // MARK: - Scrub Preview

    private static let scrubCardWidth: CGFloat = 320

    /// Frame card tracking the scrub knob (clamped inside the bar), sized to
    /// the frame's own aspect (SD 4:3 channels stay 4:3) not forced 16:9.
    private func liveScrubPreviewArea(image: CGImage) -> some View {
        let cardHeight = TransportBar.previewImageHeight(for: image)
        return GeometryReader { geo in
            let width = geo.size.width
            let half = Self.scrubCardWidth / 2
            let knobX = max(0, min(width, width * CGFloat(viewModel.scrubProgress)))
            let clampedX = max(half, min(width - half, knobX))
            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: Self.scrubCardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.Theme.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                .position(x: clampedX, y: cardHeight / 2)
        }
        .frame(height: cardHeight)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = viewModel.isScrubbing
            let trackHeight: CGFloat = active ? 10 : 6
            let knobSize: CGFloat = active ? 22 : 14
            let knobX = max(0, min(width, width * liveProgress))

            ZStack(alignment: .leading) {
                // Unplayed track white for contrast regardless of accent color.
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.tint)
                    .frame(width: knobX, height: trackHeight)

                // Live-edge tick pinned to the right end of the window.
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: trackHeight + 8)
                    .offset(x: width - 3)

                Circle()
                    .fill(.tint)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: knobX - knobSize / 2)
            }
            .animation(.easeInOut(duration: 0.2), value: active)
        }
        .frame(height: 22)
    }

    // MARK: - Derived

    /// Playhead fraction of the seekable window: in-flight scrub while
    /// scrubbing, else playhead across `liveSeekableRange`. Defaults to 1
    /// (at-live) before the window is known.
    private var liveProgress: CGFloat {
        if viewModel.isScrubbing { return CGFloat(viewModel.scrubProgress) }
        guard let range = viewModel.liveSeekableRange,
              range.upperBound > range.lowerBound else { return 1 }
        let span = range.upperBound - range.lowerBound
        let pos = viewModel.playbackTime - range.lowerBound
        return CGFloat(max(0, min(1, pos / span)))
    }

    private var positionLabel: String {
        if viewModel.isAtLiveEdge {
            return NSLocalizedString("livetv.liveBadge", comment: "Live edge label")
        }
        let behind = max(0, Int(viewModel.behindLiveSeconds))
        return String(format: "-%d:%02d", behind / 60, behind % 60)
    }
}
