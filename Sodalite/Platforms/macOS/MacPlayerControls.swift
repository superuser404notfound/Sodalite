#if os(macOS)
import SwiftUI
import AppKit

/// The transport's menus on the Mac: one native menu per control the viewer's arrangement shows
/// (`transportFocusOrder`, the same list the tvOS and iOS bars draw), filled from the same view
/// model state their dropdowns read. A pointer has no use for the remote's cursor, so nothing here
/// goes through `trackDropdown`; each item calls the selection the dropdown's Select would.
struct MacPlayerMenus: View {
    let viewModel: PlayerViewModel

    private var controls: [PlayerViewModel.ControlsFocus] {
        let order = viewModel.isLiveSession ? viewModel.liveTransportFocusOrder : viewModel.transportFocusOrder
        return order.filter(Self.supported.contains)
    }

    /// The prompts render as their own buttons (`MacPlayerPrompts`). Multiview is a tvOS grid.
    private static let supported: Set<PlayerViewModel.ControlsFocus> = [
        .restartButton, .episodeButton, .chapterButton, .audioButton, .subtitleButton,
        .qualityButton, .speedButton, .pictureButton, .upscaleButton, .pipButton, .infoButton,
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(controls, id: \.self) { control in
                switch control {
                case .restartButton:
                    MacTransportIconButton(control: .restart) { viewModel.restartFromBeginning() }
                case .episodeButton: menu(.episodes) { episodeItems }
                case .chapterButton: menu(.chapters) { chapterItems }
                case .audioButton: menu(.audio) { audioItems }
                case .subtitleButton: menu(.subtitles) { subtitleItems }
                case .qualityButton: menu(.quality) { qualityItems }
                case .speedButton: menu(.speed) { speedItems }
                case .pictureButton: menu(.picture) { pictureItems }
                case .upscaleButton:
                    MacTransportIconButton(control: .upscaling, systemImage: viewModel.upscaleChipIcon,
                                           help: viewModel.upscaleChipLabel) { viewModel.toggleUpscaling() }
                case .pipButton:
                    MacTransportIconButton(control: .pip, systemImage: "pip.enter") {
                        viewModel.requestPictureInPicture()
                    }
                    .disabled(!viewModel.isPiPPossible)
                case .infoButton:
                    MacTransportIconButton(control: .stats, isOn: viewModel.showStatsOverlay) {
                        viewModel.showStatsOverlay.toggle()
                    }
                default: EmptyView()
                }
            }
        }
    }

    private func menu<Content: View>(_ control: PlayerControl, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Image(systemName: PlayerControlsSettingsView.symbol(for: control))
                .font(.title3)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(PlayerControlsSettingsView.label(for: control))
    }

    // MARK: - Items

    /// A Toggle is what a Mac menu draws with the system checkmark in its own column.
    private func choice(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
    }

    @ViewBuilder private var audioItems: some View {
        let rows = viewModel.audioMenuRows
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            if case .track(let id) = row {
                choice(viewModel.audioMenuLabel(for: row), isOn: id == viewModel.activeAudioIndex) {
                    viewModel.selectAudioTrack(id: id, userInitiated: true)
                }
            }
        }
        let settings = rows.filter {
            switch $0 {
            case .track, .delay: false
            default: true
            }
        }
        if !settings.isEmpty {
            Divider()
            ForEach(Array(settings.enumerated()), id: \.offset) { _, row in
                Button(viewModel.audioMenuLabel(for: row)) { viewModel.cycleAudioSetting(row) }
            }
        }
        // 41 values: stepped like the subtitle timing instead of cycled.
        if rows.contains(.delay) {
            Divider()
            Section(viewModel.audioMenuLabel(for: .delay)) {
                ControlGroup {
                    Button { viewModel.stepAudioSetting(.delay, by: -1) } label: { Image(systemName: "minus") }
                    Button { viewModel.cycleAudioSetting(.delay) } label: { Image(systemName: "arrow.counterclockwise") }
                    Button { viewModel.stepAudioSetting(.delay, by: 1) } label: { Image(systemName: "plus") }
                }
                .controlGroupStyle(.palette)
            }
        }
    }

    @ViewBuilder private var subtitleItems: some View {
        choice(String(localized: "player.subtitles.off", defaultValue: "Off"),
               isOn: viewModel.activeSubtitleIndex == nil) {
            viewModel.selectSubtitleTrack(id: nil, userInitiated: true)
        }
        ForEach(viewModel.displaySubtitleStreams, id: \.index) { stream in
            choice(TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                   isOn: stream.index == viewModel.activeSubtitleIndex) {
                viewModel.selectSubtitleTrack(id: stream.index, userInitiated: true)
            }
        }
        if viewModel.subtitleMenuRows.contains(.secondaryHeader) {
            Divider()
            Menu(secondaryTitle) {
                choice(String(localized: "player.subtitles.off", defaultValue: "Off"),
                       isOn: viewModel.activeSecondarySubtitleIndex == nil) {
                    viewModel.selectSecondarySubtitleTrack(id: nil)
                }
                ForEach(viewModel.secondarySubtitleCandidates, id: \.index) { stream in
                    choice(TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                           isOn: stream.index == viewModel.activeSecondarySubtitleIndex) {
                        viewModel.selectSecondarySubtitleTrack(id: stream.index)
                    }
                }
            }
        }
        let external = viewModel.displaySubtitleStreams.filter { $0.isExternal == true }
        if !external.isEmpty {
            Menu(String(localized: "player.subtitle.delete.confirm", defaultValue: "Delete")) {
                ForEach(external, id: \.index) { stream in
                    Button(TrackDisplayFormatter.subtitleStreamDisplayName(for: stream)) {
                        viewModel.requestSubtitleDeletion(streamIndex: stream.index)
                    }
                }
            }
        }
        if viewModel.supportsSubtitleSearch {
            Button(String(localized: "player.subtitle.searchOnline", defaultValue: "Search online...")) {
                viewModel.presentSubtitleSearch()
            }
        }
        if viewModel.supportsSubtitleOffset {
            Divider()
            Section(String(format: String(localized: "player.subtitle.offset.value", defaultValue: "Timing: %@"),
                           PlaybackSettingsView.formatSubtitleDelay(viewModel.itemSubtitleOffset))) {
                ControlGroup {
                    Button { viewModel.stepSubtitleOffset(by: -1) } label: { Image(systemName: "minus") }
                    Button { viewModel.setSubtitleOffset(0) } label: { Image(systemName: "arrow.counterclockwise") }
                    Button { viewModel.stepSubtitleOffset(by: 1) } label: { Image(systemName: "plus") }
                }
                .controlGroupStyle(.palette)
            }
        }
    }

    private var secondaryTitle: String {
        guard let idx = viewModel.activeSecondarySubtitleIndex,
              let stream = viewModel.subtitleStreams.first(where: { $0.index == idx }) else {
            return String(localized: "player.subtitle.secondary.none", defaultValue: "Secondary: Off")
        }
        return String(format: String(localized: "player.subtitle.secondary.value", defaultValue: "Secondary: %@"),
                      TrackDisplayFormatter.subtitleStreamDisplayName(for: stream))
    }

    @ViewBuilder private var qualityItems: some View {
        ForEach(viewModel.pickerQualities, id: \.self) { quality in
            let title = String(localized: String.LocalizationValue(quality.titleKey))
            let hint = viewModel.qualityPickerHint(quality)
            choice(hint.map { "\(title)  \($0)" } ?? title,
                   isOn: quality == viewModel.displayedStreamingQuality) {
                viewModel.selectStreamingQuality(quality)
            }
        }
    }

    @ViewBuilder private var speedItems: some View {
        ForEach(Array(PlayerViewModel.speedOptions.enumerated()), id: \.offset) { index, rate in
            choice(Self.speedLabel(rate), isOn: index == viewModel.activeSpeedIndex) {
                viewModel.selectSpeed(index: index)
            }
        }
    }

    @ViewBuilder private var pictureItems: some View {
        ForEach(PlaybackPreferences.PictureMode.allCases, id: \.self) { mode in
            choice(String(localized: String.LocalizationValue(mode.titleKey)), isOn: mode == viewModel.pictureMode) {
                viewModel.selectPictureMode(mode)
            }
        }
    }

    @ViewBuilder private var chapterItems: some View {
        let active = viewModel.activeChapterIndex
        ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { index, chapter in
            choice(Self.chapterTitle(chapter, index: index), isOn: index == active) {
                viewModel.selectChapter(at: index)
            }
        }
    }

    @ViewBuilder private var episodeItems: some View {
        ForEach(Array(viewModel.seasonEpisodes.enumerated()), id: \.element.id) { index, episode in
            choice(episodeTitle(episode), isOn: episode.id == viewModel.item.id) {
                Task { await viewModel.selectEpisode(at: index) }
            }
        }
    }

    // MARK: - Labels

    /// "1×" / "1.5×", unlocalized like the other platforms' chip.
    static func speedLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    static func chapterTitle(_ chapter: ChapterInfo, index: Int) -> String {
        let total = Int(max(0, chapter.startSeconds))
        let stamp = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        let name = chapter.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "player.chapter.fallback", defaultValue: "Chapter \(index + 1)")
        return "\(stamp)  \(name)"
    }

    private func episodeTitle(_ episode: JellyfinItem) -> String {
        let label = EpisodeMetadataFormatter.label(season: nil, episode: episode.indexNumber,
                                                   title: viewModel.spoilerPolicy.visibleTitle(of: episode))
        return label.isEmpty ? viewModel.spoilerPolicy.displayName(of: episode) : label
    }
}

/// A transport control that acts on click rather than opening a menu.
struct MacTransportIconButton: View {
    let control: PlayerControl
    var systemImage: String? = nil
    var help: String? = nil
    /// Drawn in the accent while on, for a control that toggles a panel.
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage ?? PlayerControlsSettingsView.symbol(for: control))
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? PlayerControlsSettingsView.label(for: control))
    }
}

/// The Mac's scrub track: click or drag to seek, hover to preview, the way AetherPlayer's bar works.
/// A drag goes through the view model's scrub state, so the timecode and the preview follow it and
/// the seek commits once on release; hovering only drives the preview.
struct MacScrubBar: View {
    let viewModel: PlayerViewModel
    let onInteraction: () -> Void

    @State private var hoverFraction: Double?

    private let previewWidth: CGFloat = 200

    private var playedFraction: Double { Double(viewModel.displayedProgress) }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let knobX = CGFloat(min(max(playedFraction, 0), 1)) * width
            let emphasized = viewModel.isScrubbing || hoverFraction != nil
            let knob: CGFloat = emphasized ? 14 : 10
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Theme.restFill).frame(height: 4)
                Capsule().fill(.tint).frame(width: knobX, height: 4)
                Circle().fill(.white).frame(width: knob, height: knob).offset(x: knobX - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        viewModel.scrub(toFraction: Float(fraction(value.location.x, width)))
                        onInteraction()
                    }
                    .onEnded { value in
                        viewModel.scrub(toFraction: Float(fraction(value.location.x, width)))
                        viewModel.commitScrub()
                        onInteraction()
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if hoverFraction == nil { viewModel.scrubPreview.prewarm() }
                    let f = fraction(point.x, width)
                    hoverFraction = f
                    // A live preview answers for the rail's own timeline, which only a scrub drives.
                    if !viewModel.isScrubbing, !viewModel.isLiveSession {
                        viewModel.scrubPreview.update(fraction: Float(f), durationSeconds: viewModel.scrubReferenceDuration)
                    }
                    onInteraction()
                case .ended:
                    hoverFraction = nil
                    if !viewModel.isScrubbing { viewModel.scrubPreview.clear() }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if emphasized, let image = viewModel.scrubPreview.previewImage {
                    let at = viewModel.isScrubbing ? Double(viewModel.scrubProgress) : (hoverFraction ?? 0)
                    preview(image, seconds: at * viewModel.scrubReferenceDuration)
                        .offset(x: min(max(CGFloat(at) * width - previewWidth / 2, 0), width - previewWidth),
                                y: -24)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 20)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1))
    }

    private func preview(_ image: CGImage, seconds: Double) -> some View {
        let height = image.width > 0 ? previewWidth * CGFloat(image.height) / CGFloat(image.width) : previewWidth * 9 / 16
        return VStack(spacing: 4) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: previewWidth, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.Theme.hairline))
            Text(Duration.seconds(max(0, seconds)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.Theme.scrim, in: Capsule())
        }
        .frame(width: previewWidth)
        .shadow(radius: 6)
    }
}

/// Skip Intro / Recap and the next-episode prompt, in the corner above the transport. Unlike tvOS
/// they stay while the controls are up: a pointer reaches them where they are, so there is no
/// focus to hand over to a twin in the bar.
struct MacPlayerPrompts: View {
    let viewModel: PlayerViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let segment = viewModel.activeSkipSegment, !viewModel.showNextEpisodeOverlay {
                pill(segment.kind.buttonLabel, systemImage: "forward.end.fill", countdown: nil) {
                    viewModel.skipActiveSegment()
                }
            }
            if viewModel.showNextEpisodeOverlay, let next = viewModel.nextEpisode {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(nextEpisodeCaption(next))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    pill(String(localized: "player.nextEpisode", defaultValue: "Next Episode"),
                         systemImage: "forward.fill",
                         countdown: viewModel.isCountdownActive ? countdownFraction : nil) {
                        Task { await viewModel.playNextEpisode() }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSkipSegment)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showNextEpisodeOverlay)
    }

    private var countdownFraction: Double {
        let total = max(1, viewModel.nextEpisodeCountdownTotal)
        return Double(viewModel.nextEpisodeCountdown) / Double(total)
    }

    private func nextEpisodeCaption(_ next: JellyfinItem) -> String {
        EpisodeMetadataFormatter.label(season: next.parentIndexNumber, episode: next.indexNumber,
                                       title: viewModel.spoilerPolicy.visibleTitle(of: next))
    }

    private func pill(_ title: String, systemImage: String, countdown: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let countdown {
                    ZStack {
                        Circle().stroke(Color.Theme.hairline, lineWidth: 2)
                        Circle().trim(from: 0, to: countdown)
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: countdown)
                    }
                    .frame(width: 14, height: 14)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
    }
}

/// The subtitle layer the other platforms mount in `PlayerOverlayView`, with the Mac's own chrome
/// state in place of `showControls` so the lines lift over the transport while it is up.
struct MacSubtitleLayer: View {
    let viewModel: PlayerViewModel
    let controlsVisible: Bool

    var body: some View {
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
                delaySeconds: viewModel.effectiveSubtitleDelay,
                verticalPosition: viewModel.preferences.subtitleVerticalPosition,
                font: viewModel.preferences.subtitleFont,
                weight: viewModel.preferences.subtitleWeight,
                controlsVisible: controlsVisible,
                assRenderer: viewModel.assRenderer,
                assReloadSignal: viewModel.assReloadSignal,
                activeSubtitleCodec: viewModel.activeSubtitleCodec,
                secondarySubtitleCodec: viewModel.activeSecondarySubtitleCodec,
                hasSecondaryTrack: viewModel.activeSecondarySubtitleIndex != nil,
                videoSize: viewModel.videoSize,
                pixelAspect: viewModel.videoPixelAspect,
                pictureMode: viewModel.pictureMode
            )
            .allowsHitTesting(false)
        }
    }
}
#endif
