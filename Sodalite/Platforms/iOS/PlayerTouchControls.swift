import SwiftUI
import AetherEngine

/// Purpose-built touch controls for the iOS/iPadOS player. Custom, tinted, matching the tvOS look,
/// but designed for touch (no focus model): top bar (close + title), a bottom block with a drag
/// scrubber, a centered play/pause, and a tinted icon row whose items open compact tinted pickers.
/// Drives the shared PlayerViewModel directly; the screen gestures live in PlayerGestureCatcher below.
struct PlayerTouchControls: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    let tintColor: Color
    var episodeImageURL: (JellyfinItem) -> URL? = { _ in nil }
    var chapterThumbnail: (Int) async -> CGImage? = { _ in nil }

    @State private var activePicker: PickerKind?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isPad: Bool { hSizeClass == .regular }

    private enum PickerKind: Identifiable {
        case audio, subtitle, secondarySubtitle, speed, picture, episodes, chapters
        var id: Int { hashValue }
    }

    private var tint: Color { tintColor }

    /// Window-safe content width minus the given horizontal margin per side; UIKit truth, immune to
    /// the corrupt SwiftUI safe rect (see the fixed-width comment in body). nil (no window yet) lets
    /// .frame(width:) fall through to flexible layout.
    static func chromeContentWidth(margin: CGFloat) -> CGFloat? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first }
                .first
        guard let window else { return nil }
        let insets = window.safeAreaInsets
        return max(0, window.bounds.width - insets.left - insets.right - margin * 2)
    }

    var body: some View {
        // No safe-area-aware constructs anywhere in here: this subtree sits in controlsOverlay's
        // absolute-geometry wrapper, which applies the window insets as plain padding, because the
        // AVKit hosting pipeline serves corrupt insets in portrait (Sodalite#15 portrait clip). The
        // bottom scrim lives in that wrapper for the same reason (it needs to full-bleed).
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBlock
            }
            // FIXED width instead of horizontal padding (Sodalite#15 portrait clip): inside AVKit,
            // flexible children balloon symmetrically into a corrupt safe rect for the first seconds
            // after open/rotation in portrait, regardless of node type (measured at every level).
            // The balloon stays centered on the screen, so a fixed-width child computed from UIKit
            // truth lands correctly in both the corrupt and the healthy state.
            .frame(width: Self.chromeContentWidth(margin: isPad ? 40 : 20))
            .padding(.vertical, isPad ? 28 : 14)

            if let picker = activePicker {
                // Tap-catching scrim that closes only the picker.
                Color.black.opacity(0.001)
                    .onTapGesture { activePicker = nil }
                pickerPanel(picker)
            }
        }
        .tint(tint)
        .foregroundStyle(.white)
        // Keep the controls up while a picker is open; re-arm the auto-hide when it closes.
        .onChange(of: activePicker) { _, newValue in
            if newValue == nil { viewModel.scheduleControlsHide() }
            else { viewModel.cancelControlsHide() }
        }
        // The subtitle-delete confirmation dialog + error alert live on PlayerOverlayView's root, NOT
        // here: presentation modifiers are safe-area-aware, and any such node in this subtree re-applies
        // the corrupt portrait insets AVKit's hosting serves (Sodalite#15 portrait clip).
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            // Defer to the next runloop: dismissing the presenting modal synchronously from inside
            // this SwiftUI button (a child of that modal) leaves it half-closed (stream stops, modal
            // stays). Deferring lets the tap handler return first, then the dismiss completes.
            Button { DispatchQueue.main.async { onDismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sub = subtitleText {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()
            // Right column: action buttons up top, format badge right-aligned underneath them (echoes
            // tvOS's free-floating top-right badge). Kept out of both the button row and the title's
            // metadata line, each of which the fixed-width badge starved on a narrow phone (it always
            // won its row and crushed whatever shared it).
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    if PlayerOrientation.isPhone {
                        rotationLockButton
                    }
                    childLockButton
                    // Auto-PiP (swipe-Home) is AVKit's own; no manual button (a custom AVPictureInPictureController
                    // breaks AVKit's auto-PiP and can't survive backgrounding). AirPlay button for discoverability.
                    AirPlayRouteButton(tint: .white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                if viewModel.videoFormat != .sdr {
                    VideoFormatBadge(format: viewModel.videoFormat, compact: true)
                }
            }
        }
    }

    /// System-rotation-lock style toggle: open = follow device rotation, closed = pin the orientation
    /// the user is holding. Remembered across sessions (PlaybackPreferences.playerRotationLocked).
    /// The engaged lock fills the circle with the tint (Control Center pattern); the two padlock
    /// glyphs alone are too similar to read as an on/off state.
    private var rotationLockButton: some View {
        let locked = viewModel.preferences.playerRotationLocked
        return Button {
            if locked {
                viewModel.preferences.playerRotationLocked = false
                PlayerOrientation.follow()
            } else {
                viewModel.preferences.playerRotationLocked = true
                PlayerOrientation.lockToCurrent()
            }
        } label: {
            Image(systemName: locked ? "lock.rotation" : "lock.open.rotation")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(locked ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Child lock: one tap disables all touch input (PlayerLockOverlay takes over). A plain lock.fill
    /// padlock; the rotation lock beside it is lock.rotation (with the circular arrow), so the two
    /// stay distinguishable. Released only by the hold-to-unlock control in the overlay.
    private var childLockButton: some View {
        Button {
            viewModel.lockInput()
        } label: {
            Image(systemName: "lock.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("player.lock.engage"))
    }

    private var titleText: String {
        viewModel.item.seriesName ?? viewModel.item.name
    }

    private var subtitleText: String? {
        if viewModel.item.seriesName != nil { return viewModel.item.name }
        if let year = viewModel.item.productionYear { return String(year) }
        return nil
    }

    // MARK: - Bottom block

    private var bottomBlock: some View {
        VStack(spacing: 14) {
            if viewModel.isScrubbing, let image = viewModel.scrubPreview.previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: isPad ? 150 : 110)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.Theme.hairline, lineWidth: 1))
            }

            iconRow

            scrubber

            HStack {
                Text(viewModel.currentTime)
                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(viewModel.remainingTime)
                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: - Icon row

    // FlowLayout, not HStack: eight fixed 44pt targets with 20pt gaps need 492pt and the portrait
    // chrome is 362pt, so the row clipped at both edges. Balanced so a wrap never leaves one lonely
    // icon under a full row. Landscape and iPad still measure to a single row.
    private var iconRow: some View {
        FlowLayout(alignment: .center, spacing: isPad ? 28 : 20, balanced: true) {
            if !viewModel.isLiveSession {
                iconButton("arrow.counterclockwise") { viewModel.restartFromBeginning() }
                    .accessibilityLabel(Text("player.restart"))
            }
            if viewModel.activeSkipSegment != nil {
                iconButton("forward.end.fill") { viewModel.skipActiveSegment() }
            }
            if viewModel.seasonEpisodes.count > 1 {
                iconButton("list.bullet") { activePicker = .episodes }
            }
            // Gated on chapter data alone (it used to vanish on any series episode), and on a split-bar
            // glyph so it never reads as the episode list it can now stand next to.
            if viewModel.chapters.count > 1 {
                iconButton("rectangle.split.3x1") { activePicker = .chapters }
            }
            if !viewModel.displayAudioTracks.isEmpty {
                iconButton("speaker.wave.2") { activePicker = .audio }
            }
            if !viewModel.displaySubtitleStreams.isEmpty || viewModel.supportsSubtitleSearch {
                iconButton("captions.bubble") { activePicker = .subtitle }
            }
            iconButton("gauge.with.needle") { activePicker = .speed }
            iconButton(pictureIcon) { activePicker = .picture }
            if viewModel.preferences.showStatsForNerds {
                iconButton("info.circle", active: viewModel.showStatsOverlay) {
                    viewModel.showStatsOverlay.toggle()
                }
            }
        }
    }

    private func iconButton(_ systemImage: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button { action(); viewModel.showControlsTemporarily() } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(active ? tint : .white)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pictureIcon: String {
        switch viewModel.pictureMode {
        case .original: return "rectangle.ratio.16.to.9"
        case .fill: return "rectangle.expand.vertical"
        }
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let frac = CGFloat(viewModel.displayedProgress)
            let knobX = max(0, min(width, width * frac))
            let bufferedX = max(0, min(width, width * CGFloat(viewModel.bufferedProgress)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 6)
                if bufferedX > knobX {
                    Capsule().fill(.white.opacity(0.4)).frame(width: bufferedX, height: 6)
                }
                Capsule().fill(tint).frame(width: knobX, height: 6)
                Circle().fill(tint)
                    .frame(width: viewModel.isScrubbing ? 22 : 16, height: viewModel.isScrubbing ? 22 : 16)
                    .offset(x: knobX - (viewModel.isScrubbing ? 11 : 8))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        viewModel.scrub(toFraction: Float(max(0, min(1, value.location.x / max(width, 1)))))
                    }
                    .onEnded { _ in viewModel.commitScrub() }
            )
            .animation(.easeInOut(duration: 0.15), value: viewModel.isScrubbing)
        }
        .frame(height: 28)
    }

    // MARK: - Picker panel

    private func pickerPanel(_ picker: PickerKind) -> some View {
        let panelRows = rows(for: picker)
        let hasThumbs = panelRows.contains { $0.imageURL != nil || $0.chapterIndex != nil }
        let rowHeight: CGFloat = hasThumbs ? 56 : 44
        return VStack {
            Spacer()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(panelRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            Button {
                                if let submenu = row.opensSubmenu {
                                    activePicker = submenu
                                } else {
                                    row.action()
                                    activePicker = nil
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    thumbnail(for: row)
                                    Text(row.label)
                                        .foregroundStyle(row.isActive ? tint : .white)
                                        .lineLimit(1)
                                    Spacer()
                                    if row.isActive {
                                        Image(systemName: "checkmark").foregroundStyle(tint)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(height: rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if let deleteIndex = row.deleteStreamIndex {
                                Button {
                                    activePicker = nil
                                    viewModel.requestSubtitleDeletion(streamIndex: deleteIndex)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Color.Theme.destructive)
                                        .frame(width: 44, height: rowHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            // Size to content (capped) so a 2-track audio menu is not a tall empty panel.
            .frame(maxHeight: min(CGFloat(panelRows.count) * rowHeight, 280))
            .frame(maxWidth: hasThumbs ? (isPad ? 520 : 420) : (isPad ? 420 : 320))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
            .padding(.bottom, isPad ? 150 : 120)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func thumbnail(for row: PickerRow) -> some View {
        if let url = row.imageURL {
            AsyncCachedImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 64, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let idx = row.chapterIndex {
            ChapterThumb(index: idx, load: chapterThumbnail)
                .frame(width: 64, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct PickerRow {
        let label: String
        let isActive: Bool
        var imageURL: URL? = nil
        var chapterIndex: Int? = nil
        var opensSubmenu: PickerKind? = nil
        /// Non-nil on a deletable (external/downloaded) subtitle row: shows a trailing trash button.
        var deleteStreamIndex: Int? = nil
        let action: () -> Void
    }

    private func rows(for picker: PickerKind) -> [PickerRow] {
        switch picker {
        case .audio:
            return viewModel.displayAudioTracks.map { track in
                PickerRow(label: TrackDisplayFormatter.audioDisplayName(for: track),
                          isActive: track.id == viewModel.activeAudioIndex) {
                    viewModel.selectAudioTrack(id: track.id, userInitiated: true)
                }
            }
        case .subtitle:
            var rows: [PickerRow] = []
            // Secondary entry at the top, matching the tvOS dropdown header.
            if !viewModel.secondarySubtitleCandidates.isEmpty {
                let secondaryLabel: String
                if let sidx = viewModel.activeSecondarySubtitleIndex,
                   let stream = viewModel.secondarySubtitleCandidates.first(where: { $0.index == sidx }) {
                    secondaryLabel = String(format: String(localized: "player.subtitle.secondary.value", defaultValue: "Secondary: %@"),
                                            TrackDisplayFormatter.subtitleStreamDisplayName(for: stream))
                } else {
                    secondaryLabel = String(localized: "player.subtitle.secondary.none", defaultValue: "Secondary: Off")
                }
                rows.append(PickerRow(label: secondaryLabel,
                                      isActive: viewModel.activeSecondarySubtitleIndex != nil,
                                      opensSubmenu: .secondarySubtitle) {})
            }
            rows.append(PickerRow(label: String(localized: "player.subtitles.off", defaultValue: "Off"),
                                  isActive: viewModel.activeSubtitleIndex == nil) {
                viewModel.selectSubtitleTrack(id: nil, userInitiated: true)
            })
            rows += viewModel.displaySubtitleStreams.map { stream in
                PickerRow(label: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                          isActive: stream.index == viewModel.activeSubtitleIndex,
                          deleteStreamIndex: stream.isExternal == true ? stream.index : nil) {
                    viewModel.selectSubtitleTrack(id: stream.index, userInitiated: true)
                }
            }
            if viewModel.supportsSubtitleSearch {
                rows.append(PickerRow(label: String(localized: "player.subtitle.searchOnline", defaultValue: "Search online..."), isActive: false) {
                    viewModel.presentSubtitleSearch()
                })
            }
            return rows
        case .secondarySubtitle:
            var rows: [PickerRow] = [
                PickerRow(label: String(localized: "player.subtitles.off", defaultValue: "Off"),
                          isActive: viewModel.activeSecondarySubtitleIndex == nil) {
                    viewModel.selectSecondarySubtitleTrack(id: nil)
                }
            ]
            rows += viewModel.secondarySubtitleCandidates.map { stream in
                PickerRow(label: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                          isActive: stream.index == viewModel.activeSecondarySubtitleIndex) {
                    viewModel.selectSecondarySubtitleTrack(id: stream.index)
                }
            }
            return rows
        case .speed:
            return PlayerViewModel.speedOptions.indices.map { idx in
                PickerRow(label: TransportBar.speedLabel(for: idx),
                          isActive: idx == viewModel.activeSpeedIndex) {
                    viewModel.selectSpeed(index: idx)
                }
            }
        case .picture:
            return PlaybackPreferences.PictureMode.allCases.map { mode in
                PickerRow(label: String(localized: String.LocalizationValue(mode.titleKey)),
                          isActive: mode == viewModel.pictureMode) {
                    viewModel.selectPictureMode(mode)
                }
            }
        case .episodes:
            return viewModel.seasonEpisodes.enumerated().map { idx, ep in
                PickerRow(label: ep.name, isActive: ep.id == viewModel.item.id, imageURL: episodeImageURL(ep)) {
                    Task { await viewModel.selectEpisode(at: idx) }
                }
            }
        case .chapters:
            let active = viewModel.activeChapterIndex
            return viewModel.chapters.enumerated().map { idx, chapter in
                let name = chapter.name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(localized: "player.chapter.fallback", defaultValue: "Chapter \(idx + 1)")
                return PickerRow(label: name, isActive: idx == active, chapterIndex: idx) {
                    viewModel.selectChapter(at: idx)
                }
            }
        }
    }
}

/// Lazily loads a chapter thumbnail (async CGImage from the session FrameExtractor) for a picker row.
private struct ChapterThumb: View {
    let index: Int
    let load: (Int) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1.0).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
            }
        }
        .task(id: index) { image = await load(index) }
    }
}
