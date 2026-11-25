import SwiftUI
import AetherEngine

// MARK: - Pill label

extension TrackPickSelection {
    /// What the Audio & Subtitles pill says: the picked audio, the picked subtitle, or "Automatic"
    /// when the player will decide. It never names a track the viewer did not pick, because the page
    /// cannot know what the player's automatic choice will be without the engine's own track list.
    func pillSubtitle(for item: JellyfinItem, source: MediaSource?) -> String {
        guard let pick = resolved(for: item, source: source) else {
            return String(localized: "detail.tracks.automatic")
        }
        let streams = source?.mediaStreams ?? []
        var parts: [String] = []
        if let audio = pick.audio, let stream = streams.first(where: { $0.index == audio.streamIndex }) {
            parts.append(TrackDisplayFormatter.shortName(for: TrackSelectionMatcher.audioTrackInfo(stream, in: streams)))
        }
        switch pick.subtitle {
        case .off:
            parts.append(String(localized: "detail.tracks.subtitlesOff"))
        case .track(let index, _):
            if let stream = streams.first(where: { $0.index == index }) {
                let name = TrackDisplayFormatter.subtitleShortName(for: stream)
                parts.append(String(localized: "detail.tracks.subtitleSummary \(name)"))
            }
        case nil:
            break
        }
        return parts.isEmpty ? String(localized: "detail.tracks.automatic") : parts.joined(separator: " · ")
    }
}

// MARK: - Presentation payload

/// Drives the panel via `.menuPresentation(item:)`, for the same reason as `VersionPickerChoice`:
/// the item, the version and the pick travel in the presented value instead of being read from
/// state the content closure may have captured stale.
struct TrackPickerChoice: Identifiable {
    let id = UUID()
    let item: JellyfinItem
    let source: MediaSource
    let selection: TrackPickSelection
}

// MARK: - Panel

/// Audio and subtitle pick for the version Play will start (Sodalite#250). Two lists in one panel,
/// so a pick does not close it; Menu or a swipe down does. Rows read like the player's own menu.
struct TrackPickerSheet: View {
    let choice: TrackPickerChoice
    let tintColor: Color
    let onChange: (TrackPickSelection) -> Void

    @State private var selection: TrackPickSelection
    @FocusState private var focusedID: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }

    init(choice: TrackPickerChoice, tintColor: Color, onChange: @escaping (TrackPickSelection) -> Void) {
        self.choice = choice
        self.tintColor = tintColor
        self.onChange = onChange
        _selection = State(initialValue: choice.selection)
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let isSelected: Bool
        let apply: (inout TrackPickSelection) -> Void
    }

    private var pick: LaunchTrackPick? { selection.resolved(for: choice.item, source: choice.source) }

    private var audioRows: [Row] {
        let item = choice.item, source = choice.source
        let streams = source.mediaStreams ?? []
        let picked = pick?.audio?.streamIndex
        return [Row(id: "a|auto", title: String(localized: "detail.tracks.automatic"), isSelected: picked == nil) {
            $0.chooseAudio(nil, item: item, source: source)
        }] + TrackPickSelection.audioStreams(in: source).map { stream in
            Row(id: "a|\(stream.index)",
                title: TrackDisplayFormatter.audioDisplayName(for: TrackSelectionMatcher.audioTrackInfo(stream, in: streams)),
                isSelected: picked == stream.index) {
                $0.chooseAudio(stream, item: item, source: source)
            }
        }
    }

    private var subtitleRows: [Row] {
        let item = choice.item, source = choice.source
        let picked = pick?.subtitle
        var pickedIndex: Int?
        if case .track(let index, _) = picked { pickedIndex = index }
        return [
            Row(id: "s|auto", title: String(localized: "detail.tracks.automatic"), isSelected: picked == nil) {
                $0.chooseSubtitle(.automatic, item: item, source: source)
            },
            Row(id: "s|off", title: String(localized: "player.subtitles.off"), isSelected: picked == .off) {
                $0.chooseSubtitle(.off, item: item, source: source)
            },
        ] + TrackPickSelection.subtitleStreams(in: source).map { stream in
            Row(id: "s|\(stream.index)", title: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                isSelected: pickedIndex == stream.index) {
                $0.chooseSubtitle(.stream(stream), item: item, source: source)
            }
        }
    }

    var body: some View {
        let audio = audioRows
        let subtitles = subtitleRows
        VStack(spacing: isCompact ? 20 : 36) {
            Text("detail.tracks.button")
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: isCompact ? 12 : 16) {
                    // One audio track is no choice; the section would only list it.
                    if audio.count > 2 {
                        section("player.audio", rows: audio, isFirst: true)
                    }
                    section("player.subtitles", rows: subtitles, isFirst: audio.count <= 2)
                }
                .frame(maxWidth: 760)
                .padding(.vertical, 8)
            }
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // tvOS gets its card from the menu cover; a second material here would stack two.
        #if os(iOS)
        .background(.thinMaterial)
        #endif
        .onAppear {
            let first = audio.count > 2 ? audio : subtitles
            focusedID = first.first(where: \.isSelected)?.id ?? first.first?.id
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, rows: [Row], isFirst: Bool) -> some View {
        Text(title)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, isFirst ? 0 : (isCompact ? 8 : 16))
            .padding(.horizontal, isCompact ? 18 : 32)
        ForEach(rows) { row($0) }
    }

    private func row(_ row: Row) -> some View {
        let isFocused = focusedID == row.id
        return HStack {
            Text(row.title)
                .font(.body)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if row.isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .padding(.leading, 12)
            }
        }
        .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
        .padding(.horizontal, isCompact ? 18 : 32)
        .padding(.vertical, isCompact ? 14 : 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? tintColor : Color.Theme.surface)
        )
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .focusableSurface(true)
        .focused($focusedID, equals: row.id)
        .stableTap(isFocused: isFocused) {
            row.apply(&selection)
            onChange(selection)
        }
    }
}
