import AetherEngine
import SwiftUI

/// DVR transport for live playback: scrubber over a FIXED span of time ending at the live edge
/// (Sodalite#104, `PlayerViewModel.liveRailGeometry`), live-edge marker, position/LIVE label, and a
/// "Return to Live" pill focusable via Up (PlayerHostController routes `.returnToLiveButton` Select
/// to returnToLiveEdge); scrubbing to the right stop also snaps to live.
///
/// The span is deliberately not the seekable range: that range starts where the channel was tuned
/// and grows with the edge, so drawing a position across it walks the knob to the right end while
/// the viewer holds still. What the session actually holds is drawn as the available region.
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
                // Sodalite#104: the leading pair carries a chip's own vertical padding so its
                // baseline lands on the chips' rather than 8pt under them. Every chip in this row is
                // callout text inside `.vertical, 8`, and a bottom-aligned row lines up the padded
                // edges, not the text inside them, which is what made the row read as two rows.
                HStack(spacing: 16) {
                    if !viewModel.isPlaying {
                        PausedGlyph()
                            .font(.callout)
                    }

                    Text(positionLabel)
                        .font(.callout)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.vertical, 8)

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

                #if os(tvOS)
                if viewModel.offersMultiview {
                    TransportTrackLabel(
                        label: String(localized: "multiview.button", defaultValue: "Multiview"),
                        icon: "rectangle.split.2x2",
                        showsLabel: viewModel.controlsFocus == .multiviewButton,
                        isFocused: viewModel.controlsFocus == .multiviewButton
                    )
                }
                #endif

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

                LiveBadge(isAtLiveEdge: viewModel.isAtLiveEdge)
            }
            // Same treatment as the VOD row, and for the same reason: a transaction (not
            // .animation(value:), which lags a frame so only the immediate neighbour glides) puts
            // menu open/close, label reveal, pill scale and sibling reflow on one curve.
            .transaction { txn in
                txn.animation = .smooth(duration: 0.32)
            }

            // The rail row keeps its distance from the track: the knob grows to 22 pt at exactly the
            // moment a readout is drawn beside the clock, so the 4 pt this used to be was the
            // tightest gap in the bar and it was tightest under the one gesture that has to stay
            // legible (#104 round 2).
            VStack(spacing: 8) {
                scrubber
                VStack(spacing: 4) {
                    LiveRailLabels(viewModel: viewModel)
                    LiveNextUpLine(viewModel: viewModel)
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isScrubbing)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAtLiveEdge)
        .animation(.smooth(duration: 0.25), value: viewModel.isPlaying)
        .animation(.smooth(duration: 0.32), value: viewModel.controlsFocus)
        .animation(.smooth(duration: 0.32), value: viewModel.trackDropdown)
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

    // MARK: - Meter

    /// Sodalite#104: the programme on air as a block of wall clock, with the DVR buffer painted
    /// inside it. Four zones, because "what has aired", "what this session recorded", "what you have
    /// watched" and "what is still to come" are four different facts and the old single tint over a
    /// faint track said none of them.
    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = viewModel.isScrubbing
            let trackHeight: CGFloat = active ? 10 : 6
            let knobSize: CGFloat = active ? 22 : 14
            let knobX = clamp(liveProgress, width)
            let availableX = clamp(CGFloat(railGeometry.availableFrom), width)
            let edgeX = clamp(CGFloat(railGeometry.liveEdge), width)

            ZStack(alignment: .leading) {
                // The block itself: everything in it that has not aired yet.
                Capsule()
                    .fill(Color.Theme.trackOnScrim)
                    .frame(height: trackHeight)

                // Before the recording starts. DARKENED, not a lighter wash: a translucent white over
                // the track composites BRIGHTER than the track, which says the opposite of "this is
                // time you do not have".
                if availableX > 0 {
                    Capsule()
                        .fill(.black.opacity(0.55))
                        .frame(width: availableX, height: trackHeight)
                }

                // Recorded and not yet watched, which on a match is the answer to "can I skip this ad
                // break". Same band the VOD bar draws for buffered-ahead.
                if edgeX > knobX {
                    Capsule()
                        .fill(.white.opacity(0.4))
                        .frame(width: edgeX - knobX, height: trackHeight)
                        .offset(x: knobX)
                }

                // Quarter-hour marks, above the track and below the watched fill so they melt into the
                // tint behind the playhead, exactly as the chapter ticks do on a stored title.
                ForEach(viewModel.liveRailBlock.quarterHourFractions, id: \.self) { fraction in
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: 2, height: trackHeight + 4)
                        .offset(x: width * CGFloat(fraction) - 1)
                }

                // Watched.
                if knobX > availableX {
                    Capsule()
                        .fill(.tint)
                        .frame(width: knobX - availableX, height: trackHeight)
                        .offset(x: availableX)
                }

                // The live edge, where it actually is inside the block rather than pinned to the right
                // end of it. On the programme on air it walks across the block as the hour passes.
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: trackHeight + 8)
                    .offset(x: min(edgeX, width - 3))

                SeekTrail(readout: viewModel.seekReadout,
                          originX: clamp(CGFloat(viewModel.scrubStartProgress), width),
                          knobX: knobX,
                          trackHeight: trackHeight)

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

    /// Where the knob is drawn: the in-flight scrub while scrubbing, else the rail.
    ///
    /// Sodalite#104: one decision, `PlayerViewModel.liveDisplayedProgress`, which the iOS bar reads
    /// too. This used to be the view's own copy of the arithmetic, and that is what the device round
    /// still showed after the engine half had landed: the badge said LIVE while the knob snapped left
    /// by a whole segment at every cut, because the two were answering different questions about the
    /// same stepping edge.
    private var liveProgress: CGFloat {
        CGFloat(viewModel.liveDisplayedProgress)
    }

    /// Sodalite#104: the rail is a block of wall clock, and what the session holds inside it is drawn
    /// rather than used as the scale. Every part of it comes from one decision in the view model, so
    /// the knob, the zones and a scrub target cannot disagree about what the rail means.
    private var railGeometry: PlayerViewModel.LiveRailGeometry {
        viewModel.liveRail
    }

    private var positionLabel: String {
        viewModel.livePositionLabel
    }

    private func clamp(_ fraction: CGFloat, _ width: CGFloat) -> CGFloat {
        max(0, min(width, width * fraction))
    }

}
