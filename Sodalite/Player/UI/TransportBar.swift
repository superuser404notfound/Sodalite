import SwiftUI
import AetherEngine

/// Native tvOS-style transport bar with progress bar, time labels,
/// and track selection buttons with dropdown menus.
///
/// Layout (dropdown open):
/// ```
///                    ┌──────────────┐
///                    │ English  ✓   │
///                    │ German       │
///                    │ Japanese     │
///                    └──────────────┘
///                         [Audio ▲]  [Subs]
/// ═══════════════════●══════════════════════
/// 00:12:34                        -01:23:45
/// ```
struct TransportBar: View {
    // The ~10 Hz clock values are read from the view model INSIDE this body (via the shims below) rather
    // than passed down as scalars, so the parent PlayerOverlayView body does not re-evaluate every tick
    // while the controls are visible; only this transport bar does. (perf: observation altitude)
    let viewModel: PlayerViewModel
    private var progress: Float { viewModel.displayedProgress }
    private var currentTime: String { viewModel.currentTime }
    private var remainingTime: String { viewModel.remainingTime }
    private var isScrubbing: Bool { viewModel.isScrubbing }
    private var scrubTime: String { viewModel.scrubTime }
    private var bufferedProgress: Float { viewModel.bufferedProgress }
    private var isPaused: Bool { !viewModel.isPlaying }
    let audioTracks: [TrackInfo]
    let subtitleStreams: [MediaStream]
    let activeAudioIndex: Int?
    let activeSubtitleIndex: Int?
    /// Currently-applied SECONDARY subtitle stream index, or nil when no companion line shows.
    let activeSecondarySubtitleIndex: Int?
    /// Streams eligible as the secondary line (text codecs, excluding the primary).
    let secondarySubtitleCandidates: [MediaStream]
    /// Show the subtitle button even with zero streams so "Search online..." stays reachable.
    let supportsSubtitleSearch: Bool
    let activeSpeedIndex: Int
    let controlsFocus: PlayerViewModel.ControlsFocus
    let trackDropdown: PlayerViewModel.TrackDropdown
    /// Label of the skippable segment (intro or recap) at the leftmost slot, nil when there is nothing
    /// to skip; the floating glass version is suppressed while the transport is open.
    let skipSegmentLabel: String?
    /// Label of the next-episode prompt while it is up, nil otherwise. With the transport open the
    /// floating pill is suppressed and the prompt lives here instead, so Select keeps meaning what
    /// the focused control says it means (Sodalite#103).
    let nextEpisodeLabel: String?
    /// Remaining fraction of the autoplay countdown, nil when none is running. The countdown does
    /// not stop when the transport opens, so it has to stay visible somewhere.
    let nextEpisodeCountdownProgress: Double?
    /// Current season's episodes; button suppressed when count <= 1.
    let seasonEpisodes: [JellyfinItem]
    let activeEpisodeID: String?
    /// Resolves an episode row thumbnail URL; a closure so the view stays unaware of the service layer.
    let episodeImageURL: (JellyfinItem) -> URL?
    /// Source-container chapters (sorted by start); button suppressed when count <= 1.
    let chapters: [ChapterInfo]
    /// Total runtime in seconds, used to position chapter ticks on the progress bar.
    let durationSeconds: Double
    /// Resolves a chapter thumbnail via the session FrameExtractor; closure keeps the view
    /// unaware of the engine/extractor.
    let chapterThumbnail: @Sendable (Int) async -> CGImage?
    let pictureMode: PlaybackPreferences.PictureMode
    /// "Stats for Nerds" info chip (off by default); toggles a side-panel overlay, no dropdown.
    let showsInfoButton: Bool
    /// PiP chip (tvOS, native path only); dimmed while AVKit reports PiP not possible.
    let showsPiPButton: Bool
    let isPiPEnabled: Bool
    /// Whether the stats panel is open; gives the chip a "pressed" look so the state reads visually.
    let isStatsOverlayOpen: Bool
    /// Scrub-position preview frame; nil falls back to the time-only label.
    let previewImage: CGImage?

    var body: some View {
        VStack(spacing: 10) {
            if isScrubbing {
                scrubPreviewArea
            }

            HStack(alignment: .bottom, spacing: 16) {
                Spacer()

                trackButton(
                    label: String(localized: "player.restart", defaultValue: "Restart"),
                    icon: "arrow.counterclockwise",
                    isFocused: controlsFocus == .restartButton,
                    persistsLabel: false,
                    dropdown: [],
                    isOpen: false
                )

                if let skipSegmentLabel {
                    trackButton(
                        label: skipSegmentLabel,
                        icon: "forward.end.fill",
                        isFocused: controlsFocus == .skipSegmentButton,
                        persistsLabel: false,
                        dropdown: [],
                        isOpen: false
                    )
                }

                if let nextEpisodeLabel {
                    trackButton(
                        label: nextEpisodeLabel,
                        icon: "play.fill",
                        isFocused: controlsFocus == .nextEpisodeButton,
                        persistsLabel: true,
                        dropdown: [],
                        isOpen: false,
                        countdownProgress: nextEpisodeCountdownProgress
                    )
                }

                if seasonEpisodes.count > 1 {
                    trackButton(
                        label: episodeButtonLabel,
                        icon: "list.bullet",
                        isFocused: controlsFocus == .episodeButton,
                        // No off-state to report, so nothing to pin: focus (and an open menu, which
                        // holds focus) still reveals "S1, E5". Same rule as Speed at 1x (#124).
                        persistsLabel: false,
                        dropdown: episodeDropdownItems,
                        isOpen: isEpisodeDropdownOpen
                    )
                }

                // Gated on chapter data alone. It used to be suppressed on any series episode, which
                // took chapter navigation away from every remux that carries real ones. The split-bar
                // glyph is what keeps it apart from the episode list next to it.
                if chapters.count > 1 {
                    trackButton(
                        label: chapterButtonLabel,
                        icon: "rectangle.split.3x1",
                        isFocused: controlsFocus == .chapterButton,
                        persistsLabel: false,
                        dropdown: chapterDropdownItems,
                        isOpen: isChapterDropdownOpen
                    )
                }

                if !audioTracks.isEmpty {
                    let activeTrack = audioTracks.first(where: { $0.id == activeAudioIndex })
                    trackButton(
                        label: activeTrack.map { TrackDisplayFormatter.shortName(for: $0) }
                            ?? String(localized: "player.audio", defaultValue: "Audio"),
                        icon: "speaker.wave.2",
                        isFocused: controlsFocus == .audioButton,
                        persistsLabel: false,
                        dropdown: audioDropdownItems,
                        isOpen: isAudioDropdownOpen
                    )
                }

                if !subtitleStreams.isEmpty || supportsSubtitleSearch {
                    let activeStream = activeSubtitleIndex.flatMap { idx in
                        subtitleStreams.first(where: { $0.index == idx })
                    }
                    trackButton(
                        label: activeStream.map { TrackDisplayFormatter.subtitleShortName(for: $0) }
                            ?? String(localized: "player.subtitles.off", defaultValue: "Off"),
                        icon: "captions.bubble",
                        isFocused: controlsFocus == .subtitleButton,
                        // Subtitles are the one picker here with an off-state, so this is the chip
                        // that follows Speed literally: "Off" is the default and needs no words.
                        // Keyed on the resolved stream, not the index: an index with no stream
                        // behind it renders "Off", and pinning that would be a lie.
                        persistsLabel: activeStream != nil,
                        dropdown: {
                            if case .secondarySubtitle = trackDropdown { return secondarySubtitleDropdownItems }
                            return subtitleDropdownItems
                        }(),
                        isOpen: isSubtitleDropdownOpen || isSecondarySubtitleDropdownOpen
                    )
                }

                trackButton(
                    label: TransportBar.speedLabel(for: activeSpeedIndex),
                    icon: "gauge.with.needle",
                    isFocused: controlsFocus == .speedButton,
                    // Label persists only off 1x; at normal speed it collapses to the gauge icon.
                    persistsLabel: !TransportBar.isDefaultSpeed(activeSpeedIndex),
                    dropdown: speedDropdownItems,
                    isOpen: isSpeedDropdownOpen
                )

                trackButton(
                    label: pictureButtonLabel,
                    icon: pictureButtonIcon,
                    isFocused: controlsFocus == .pictureButton,
                    // Icon already swaps 16:9 vs fill glyph, so the mode reads without a pinned label.
                    persistsLabel: false,
                    dropdown: pictureDropdownItems,
                    isOpen: isPictureDropdownOpen
                )

                if showsPiPButton {
                    trackButton(
                        label: String(localized: "player.pip", defaultValue: "Picture in Picture"),
                        icon: "pip.enter",
                        isFocused: controlsFocus == .pipButton,
                        persistsLabel: false,
                        dropdown: [],
                        isOpen: false
                    )
                    .opacity(isPiPEnabled ? 1.0 : 0.4)
                }

                if showsInfoButton {
                    // Info chip toggles the stats side panel (no dropdown); looks pressed while open.
                    trackButton(
                        label: String(localized: "player.stats", defaultValue: "Stats"),
                        icon: "info.circle",
                        isFocused: controlsFocus == .infoButton || isStatsOverlayOpen,
                        persistsLabel: false,
                        dropdown: [],
                        isOpen: false
                    )
                }
            }
            .padding(.bottom, 4)
            // Transaction (not .animation(value:), which lagged a frame so only the immediate
            // neighbor glided) puts label reveal, pill scale, and sibling reflow on one curve.
            .transaction { txn in
                txn.animation = .smooth(duration: 0.32)
            }

            progressBar

            HStack(spacing: 8) {
                if isPaused {
                    PausedGlyph()
                        .font(.callout)
                }

                Text(currentTime)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Text(remainingTime)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
        .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        .animation(.smooth(duration: 0.25), value: isPaused)
        .animation(.smooth(duration: 0.32), value: controlsFocus)
        .animation(.smooth(duration: 0.32), value: trackDropdown)
    }

    // MARK: - Scrub Preview

    private static let scrubCardWidth: CGFloat = 320

    @ViewBuilder
    private var scrubPreviewArea: some View {
        if let previewImage {
            let imageHeight = Self.previewImageHeight(for: previewImage)
            let cardHeight = imageHeight + 34
            GeometryReader { geo in
                let width = geo.size.width
                let half = Self.scrubCardWidth / 2
                let knobX = max(0, min(width, width * CGFloat(progress)))
                let clampedX = max(half, min(width - half, knobX))
                scrubPreviewCard(image: previewImage, imageHeight: imageHeight)
                    .position(x: clampedX, y: cardHeight / 2)
            }
            .frame(height: cardHeight)
            .padding(.bottom, 12)
            .transition(.opacity)
        } else {
            Text(scrubTime)
                .font(.system(size: 56, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .transition(.opacity)
                .padding(.bottom, 16)
        }
    }

    /// Preview height at the fixed card width from the frame's own (SAR-corrected) aspect, so a
    /// 4:3 DVD stays 4:3 instead of being stretched to 16:9. Clamped; degenerate frames use 16:9.
    static func previewImageHeight(for image: CGImage) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return scrubCardWidth * 9 / 16 }
        let h = scrubCardWidth * CGFloat(image.height) / CGFloat(image.width)
        return min(max(h, scrubCardWidth * 9 / 21), scrubCardWidth)
    }

    private func scrubPreviewCard(image: CGImage, imageHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: Self.scrubCardWidth, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.Theme.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

            Text(scrubTime)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    // MARK: - Dropdown State

    private var isAudioDropdownOpen: Bool {
        if case .audio = trackDropdown { return true }
        return false
    }

    private var isSubtitleDropdownOpen: Bool {
        if case .subtitle = trackDropdown { return true }
        return false
    }

    private var isSecondarySubtitleDropdownOpen: Bool {
        if case .secondarySubtitle = trackDropdown { return true }
        return false
    }

    private var isSpeedDropdownOpen: Bool {
        if case .speed = trackDropdown { return true }
        return false
    }

    private var isEpisodeDropdownOpen: Bool {
        if case .episode = trackDropdown { return true }
        return false
    }

    private var isChapterDropdownOpen: Bool {
        if case .chapter = trackDropdown { return true }
        return false
    }

    private var isPictureDropdownOpen: Bool {
        if case .picture = trackDropdown { return true }
        return false
    }

    private var pictureButtonIcon: String {
        switch pictureMode {
        case .original: return "rectangle.ratio.16.to.9"
        case .fill:     return "rectangle.expand.vertical"
        }
    }

    private var pictureButtonLabel: String {
        String(localized: String.LocalizationValue(pictureMode.titleKey))
    }

    private var pictureDropdownItems: [DropdownItem] {
        guard case .picture(let highlighted) = trackDropdown else { return [] }
        return PlaybackPreferences.PictureMode.allCases.enumerated().map { idx, mode in
            DropdownItem(
                title: String(localized: String.LocalizationValue(mode.titleKey)),
                isActive: mode == pictureMode,
                isHighlighted: idx == highlighted
            )
        }
    }

    /// Active chapter for the CHIP: last chapter starting at or before the scrub position. Deliberately
    /// not `viewModel.activeChapterIndex`, which rides `sourceTime` (the frame on screen) so an opening
    /// dropdown lands on what you are watching. A pinned chip instead has to name where the scrub is
    /// heading, or it sits still while the bar moves under it.
    private var activeChapterIndex: Int? {
        guard !chapters.isEmpty else { return nil }
        let nowSeconds = Double(progress) * max(durationSeconds, 0)
        var idx = 0
        for (i, chapter) in chapters.enumerated() {
            if chapter.startSeconds <= nowSeconds + 0.001 {
                idx = i
            } else {
                break
            }
        }
        return idx
    }

    /// "3 / 12", the position and nothing else. The chip pins its label now, and a chapter name is
    /// unbounded ("The Trial of the Chicago Seven") where `.fixedSize()` would let it shove the whole
    /// right-aligned row off the screen. Names live in the dropdown rows, which have room for them.
    /// Same trade the episode chip makes with "S1, E5" over the episode title.
    private var chapterButtonLabel: String {
        guard let i = activeChapterIndex else {
            return String(localized: "player.chapters", defaultValue: "Chapters")
        }
        return "\(i + 1) / \(chapters.count)"
    }

    /// "S1, E5" when the active episode is numbered, else a generic label.
    private var episodeButtonLabel: String {
        if let active = seasonEpisodes.first(where: { $0.id == activeEpisodeID }) {
            let token = EpisodeMetadataFormatter.seasonEpisode(season: active.parentIndexNumber,
                                                               episode: active.indexNumber)
            if !token.isEmpty { return token }
        }
        return String(localized: "player.episodes", defaultValue: "Episodes")
    }

    private var episodeDropdownItems: [DropdownItem] {
        guard case .episode(let highlighted) = trackDropdown else { return [] }
        return seasonEpisodes.enumerated().map { idx, episode in
            DropdownItem(
                title: episodeRowTitle(for: episode),
                isActive: episode.id == activeEpisodeID,
                isHighlighted: idx == highlighted,
                image: episodeImageURL(episode).map(DropdownImage.url)
            )
        }
    }

    private var chapterDropdownItems: [DropdownItem] {
        guard case .chapter(let highlighted) = trackDropdown else { return [] }
        let active = activeChapterIndex
        return chapters.enumerated().map { idx, chapter in
            DropdownItem(
                title: chapterRowTitle(for: chapter, index: idx),
                isActive: idx == active,
                isHighlighted: idx == highlighted,
                image: .chapterThumbnail(idx)
            )
        }
    }

    /// "12:34  Name" (timestamp first so dropdown rows stay aligned), falling back to "Chapter N".
    private func chapterRowTitle(for chapter: ChapterInfo, index: Int) -> String {
        let stamp = TransportBar.formatChapterTime(chapter.startSeconds)
        let name = chapter.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "player.chapter.fallback", defaultValue: "Chapter \(index + 1)")
        return "\(stamp)  \(name)"
    }

    private static func formatChapterTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// "E5 · Title": the dropdown lists one season, so the season number is implied by the row above it.
    private func episodeRowTitle(for episode: JellyfinItem) -> String {
        EpisodeMetadataFormatter.label(season: nil, episode: episode.indexNumber,
                                       title: episode.name)
    }

    /// "1×" / "1.5×", deliberately not localized (× glyph + arabic digits are universal).
    static func speedLabel(for index: Int) -> String {
        let rate = PlayerViewModel.speedOptions[
            max(0, min(PlayerViewModel.speedOptions.count - 1, index))
        ]
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        // Strip trailing zeros (0.50 → 0.5)
        let s = String(format: "%.2f", rate)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "\(s)×"
    }

    static func isDefaultSpeed(_ index: Int) -> Bool {
        let rate = PlayerViewModel.speedOptions[
            max(0, min(PlayerViewModel.speedOptions.count - 1, index))
        ]
        return rate == 1.0
    }

    private var audioDropdownItems: [DropdownItem] {
        guard case .audio(let highlighted) = trackDropdown else { return [] }
        return audioTracks.enumerated().map { idx, track in
            DropdownItem(
                title: TrackDisplayFormatter.audioDisplayName(for: track),
                isActive: track.id == activeAudioIndex,
                isHighlighted: idx == highlighted
            )
        }
    }

    private var subtitleDropdownItems: [DropdownItem] {
        guard case .subtitle(let highlighted) = trackDropdown else { return [] }
        let secondaryName: String = {
            guard let idx = activeSecondarySubtitleIndex,
                  let stream = subtitleStreams.first(where: { $0.index == idx }) else {
                return String(localized: "player.subtitle.secondary.none", defaultValue: "Secondary: Off")
            }
            return String(format: String(localized: "player.subtitle.secondary.value", defaultValue: "Secondary: %@"),
                          TrackDisplayFormatter.subtitleStreamDisplayName(for: stream))
        }()
        return viewModel.subtitleMenuRows.enumerated().map { index, row in
            switch row {
            case .secondaryHeader:
                return DropdownItem(title: secondaryName, isActive: false,
                                    isHighlighted: highlighted == index,
                                    isPinnedHeader: true, separatorBelow: true)
            case .off:
                return DropdownItem(title: String(localized: "player.subtitles.off", defaultValue: "Off"),
                                    isActive: activeSubtitleIndex == nil,
                                    isHighlighted: highlighted == index)
            case .track(let streamIndex):
                let stream = subtitleStreams.first(where: { $0.index == streamIndex })
                return DropdownItem(
                    title: stream.map(TrackDisplayFormatter.subtitleStreamDisplayName(for:)) ?? "",
                    isActive: streamIndex == activeSubtitleIndex,
                    isHighlighted: highlighted == index,
                    hint: stream?.isExternal == true
                        ? String(localized: "player.subtitle.delete.hint", defaultValue: "Hold to delete")
                        : nil
                )
            case .searchOnline:
                return DropdownItem(
                    title: String(localized: "player.subtitle.searchOnline", defaultValue: "Search online..."),
                    isActive: false,
                    isHighlighted: highlighted == index,
                    isPinnedFooter: true,
                    separatorAbove: true
                )
            }
        }
    }

    private var secondarySubtitleDropdownItems: [DropdownItem] {
        guard case .secondarySubtitle(let highlighted) = trackDropdown else { return [] }
        var items: [DropdownItem] = [
            DropdownItem(
                title: String(localized: "player.subtitle.secondary.back", defaultValue: "Back"),
                isActive: false,
                isHighlighted: highlighted == 0,
                isPinnedHeader: true,
                separatorBelow: true
            ),
            DropdownItem(
                title: String(localized: "player.subtitles.off", defaultValue: "Off"),
                isActive: activeSecondarySubtitleIndex == nil,
                isHighlighted: highlighted == 1
            )
        ]
        items += secondarySubtitleCandidates.enumerated().map { idx, stream in
            DropdownItem(
                title: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                isActive: stream.index == activeSecondarySubtitleIndex,
                isHighlighted: idx + 2 == highlighted
            )
        }
        return items
    }

    private var speedDropdownItems: [DropdownItem] {
        guard case .speed(let highlighted) = trackDropdown else { return [] }
        return PlayerViewModel.speedOptions.enumerated().map { idx, _ in
            DropdownItem(
                title: TransportBar.speedLabel(for: idx),
                isActive: idx == activeSpeedIndex,
                isHighlighted: idx == highlighted
            )
        }
    }

    // MARK: - Track Button + Dropdown

    private func trackButton(label: String, icon: String, isFocused: Bool, persistsLabel: Bool, dropdown: [DropdownItem], isOpen: Bool, countdownProgress: Double? = nil) -> some View {
        // 12, not 6: the menu was crammed onto its own chip (#124). The column grows upward from a
        // fixed bottom, and the tallest menu (six 84pt episode rows) tops out 712pt up at 1080p, so
        // the extra 6 comes out of 368pt of headroom.
        VStack(spacing: 12) {
            if isOpen {
                PlayerTrackDropdownList(items: dropdown, chapterThumbnail: chapterThumbnail)
            }

            TransportTrackLabel(
                label: label,
                icon: icon,
                showsLabel: persistsLabel || isFocused,
                isFocused: isFocused,
                countdownProgress: countdownProgress
            )
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = max(0, min(width, width * CGFloat(progress)))
            let bufferedX = max(0, min(width, width * CGFloat(bufferedProgress)))
            let active = isScrubbing || controlsFocus == .progressBar
            let trackHeight: CGFloat = active ? 10 : 6
            let knobSize: CGFloat = active ? 22 : 14

            ZStack(alignment: .leading) {
                // Unplayed track stays white for contrast regardless of the user's accent color.
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                // Buffered-ahead (disk cache read-ahead) sits above the unplayed track and below the
                // played tint, lighter than the tint so the played portion still reads as primary. Only
                // when it actually leads the playhead, so it collapses when the frontier is at the knob.
                if bufferedX > knobX {
                    Capsule()
                        .fill(.white.opacity(0.4))
                        .frame(width: bufferedX, height: trackHeight)
                }

                // Chapter ticks, drawn above the unplayed track and below the played portion so
                // they melt into the tint behind the playhead. Skip the first (at 0:00, edge collision).
                if chapters.count > 1, durationSeconds > 0 {
                    ForEach(chapters.dropFirst().indices, id: \.self) { i in
                        let frac = chapters[i].startSeconds / durationSeconds
                        if frac > 0, frac < 1 {
                            Capsule()
                                .fill(.white.opacity(0.55))
                                .frame(width: 2, height: trackHeight + 4)
                                .offset(x: width * CGFloat(frac) - 1)
                        }
                    }
                }

                // Played portion + knob follow the active tint to match the focused UI accent.
                Capsule()
                    .fill(.tint)
                    .frame(width: knobX, height: trackHeight)

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
}

// MARK: - Transport Track Button Label

/// A track button's always-visible icon + width-animated text label (revealed when `showsLabel`).
/// Driven by an explicit `isFocused` flag, not `@Environment(\.isFocused)`, because transport-bar
/// focus lives in `PlayerViewModel.controlsFocus`, not the SwiftUI focus system.
// MARK: - Title Overlay

struct PlayerTitleOverlay: View {
    let item: JellyfinItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let seriesName = item.seriesName {
                Text(seriesName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                let episodeLabel = episodeDescription
                if !episodeLabel.isEmpty {
                    Text(episodeLabel)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                Text(item.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let year = item.productionYear {
                    Text(String(year))
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 60)
    }

    private var episodeDescription: String {
        EpisodeMetadataFormatter.label(season: item.parentIndexNumber,
                                       episode: item.indexNumber,
                                       title: item.name)
    }
}

// MARK: - Paused Glyph

/// Sodalite#93: on tvOS the only thing on screen that says "paused" rather than "stalled". Sits at the
/// leading edge of the time row in both tvOS transports, VOD and live, so the two read alike; the caller
/// sets the font because those rows do not share a type scale. The iOS touch controls carry their own
/// play/pause button in that same row and need no second glyph beside it.
struct PausedGlyph: View {
    var body: some View {
        Image(systemName: "pause.fill")
            .fontWeight(.medium)
            .foregroundStyle(.white.opacity(0.7))
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}
