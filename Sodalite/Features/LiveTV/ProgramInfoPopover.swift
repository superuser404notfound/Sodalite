import SwiftUI

struct ProgramInfoPopover: View {
    let program: JellyfinProgram
    let channel: JellyfinChannel
    let tint: Color
    /// Launch live playback when the user taps Watch Live.
    var onWatchLive: ((LivePlaybackContext) -> Void)?
    var channelIsFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?
    /// Record state + toggles, from the guide's view model.
    var hasTimer: Bool = false
    var hasSeriesTimer: Bool = false
    var onToggleRecord: (() -> Void)?
    var onToggleSeriesRecord: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Local mirror for snappy feedback; the view model is source of truth and persists.
    @State private var isFavorite: Bool = false
    @State private var isRecording: Bool = false
    @State private var isSeriesRecording: Bool = false

    private var isAiring: Bool { program.isAiring(at: Date()) }

    var body: some View {
        layout
            .onAppear {
                isFavorite = channelIsFavorite
                isRecording = hasTimer
                isSeriesRecording = hasSeriesTimer
            }
            // Resync local mirrors when model timer state changes under the open popover (rollback /
            // reconcile); else the button kept its flipped state until reopened.
            .onChange(of: hasTimer) { _, newValue in
                isRecording = newValue
            }
            .onChange(of: hasSeriesTimer) { _, newValue in
                isSeriesRecording = newValue
            }
    }

    @ViewBuilder
    private var layout: some View {
        if hSizeClass == .compact {
            // Phone: scroll so a long overview + stacked buttons never clip, and the wide action row
            // (up to four pills) wraps to a vertical column that always fits ~393pt.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoBlock
                    VStack(alignment: .leading, spacing: 12) { actionButtons }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                infoBlock
                HStack(spacing: 20) { actionButtons }
                Spacer()
            }
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var infoBlock: some View {
        Text(program.name).font(hSizeClass == .compact ? .title2 : .title)
        // Episode identity — prefers episode title as the primary label, falls back to series name.
        if let label = episodeLabel {
            Text(label)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        if let start = program.startDate, let end = program.endDate {
            Text("\(channel.name) · \(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                .font(.headline).foregroundStyle(.secondary)
        }
        if let genres = program.genres, !genres.isEmpty {
            Text(genres.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        if let overview = program.overview {
            Text(overview).font(.body).lineLimit(8)
        }
    }

    /// Builds the episode-identity label with cascading priority:
    /// episodeTitle > seriesName > S/E numbers alone.
    var episodeLabel: String? {
        let se = if let s = program.parentIndexNumber, let e = program.indexNumber {
            "S\(s):E\(e)"
        } else {
            nil as String?
        }
        if let title = program.episodeTitle {
            return se.map { "\($0) · \(title)" } ?? title
        }
        if let series = program.seriesName {
            return se.map { "\(series) · \($0)" } ?? series
        }
        return se
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isAiring {
            PopoverActionButton(title: "livetv.watchLive", systemImage: "play.fill", accent: tint) {
                dismiss()
                onWatchLive?(LivePlaybackContext(channel: channel, program: program))
            }
        }
        PopoverActionButton(
            title: isFavorite ? "livetv.unfavorite" : "livetv.favorite",
            systemImage: isFavorite ? "star.fill" : "star",
            accent: isFavorite ? .yellow : tint
        ) {
            isFavorite.toggle()
            onToggleFavorite?()
        }
        // Record affordances only for future / currently airing programs.
        if let end = program.endDate, end > Date(), !program.isSynthesized {
            PopoverActionButton(
                title: isRecording ? "livetv.cancelRecording" : "livetv.record",
                systemImage: isRecording ? "stop.circle" : "record.circle",
                accent: isRecording ? .red : tint
            ) {
                isRecording.toggle()
                onToggleRecord?()
            }
            if program.isSeries == true {
                PopoverActionButton(
                    title: isSeriesRecording ? "livetv.cancelSeriesRecording" : "livetv.recordSeries",
                    systemImage: isSeriesRecording ? "stop.circle.fill" : "record.circle.fill",
                    accent: isSeriesRecording ? .red : tint
                ) {
                    isSeriesRecording.toggle()
                    onToggleSeriesRecord?()
                }
            }
        }
    }
}

/// Raw `.focusable` surface, not a `Button`: tvOS's default Button over a sheet renders only the
/// focused button's label, leaving the unfocused one a blank tinted pill. Always shows the label,
/// fills tinted when focused (app convention), mirroring the Return-to-Live pill + BoolPillRow.
private struct PopoverActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accent: Color
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(
                Capsule().fill(focused ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.12)))
            )
            .overlay(
                Capsule().strokeBorder(accent, lineWidth: focused ? 0 : 2)
            )
            .scaleEffect(focused ? 1.06 : 1.0)
            .focusable()
            .focused($focused)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .stableTap(isFocused: focused) { action() }
    }
}
