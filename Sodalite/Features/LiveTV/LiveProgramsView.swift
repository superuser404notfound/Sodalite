import SwiftUI

/// Bundles the tapped program + its (real or synthesized) channel so the
/// info sheet receives both atomically (same race fix as EPGSelection).
private struct ProgramSelection: Identifiable {
    let channel: JellyfinChannel
    let program: JellyfinProgram
    var id: String { "\(channel.id)-\(program.id)" }
}

/// Live TV "Übersicht": recommended programs in category rows. Reads the shared `LiveTimerStore`
/// for record/favorite state so the optimistic overlay stays consistent across segments.
struct LiveProgramsView: View {
    @State private var model: LiveProgramsViewModel
    let timers: LiveTimerStore
    /// The guide's channel list, used to upgrade a tapped program's synthesized channel to the real one.
    let guideChannels: [JellyfinChannel]
    let tint: Color
    /// True while the live player covers the screen. The rows are not worth refreshing behind it,
    /// and the moment it flips back is exactly when the snapshot has aged by a whole program (#96).
    let isPlayerPresented: Bool
    /// Whether the Live TV tab is the selected one. A background tab keeps its content in the
    /// hierarchy, so neither the task nor onDisappear can be trusted to stop the clock there.
    let isTabSelected: Bool
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: ProgramSelection?

    init(model: LiveProgramsViewModel,
         timers: LiveTimerStore,
         guideChannels: [JellyfinChannel],
         tint: Color,
         isPlayerPresented: Bool,
         isTabSelected: Bool,
         onWatchLive: ((LivePlaybackContext) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.timers = timers
        self.guideChannels = guideChannels
        self.tint = tint
        self.isPlayerPresented = isPlayerPresented
        self.isTabSelected = isTabSelected
        self.onWatchLive = onWatchLive
    }

    /// The rows only have to describe "now" while someone is looking at them. The section is implicit:
    /// this view exists only while the overview segment is the selected one.
    private var isWatched: Bool { isTabSelected && !isPlayerPresented && scenePhase == .active }

    var body: some View {
        Group {
            if model.rows.isEmpty && model.isLoading {
                ProgressView()
            } else if model.rows.isEmpty, let err = model.loadError {
                ContentUnavailableView(
                    "livetv.loadFailed.title",
                    systemImage: "tv.slash",
                    description: Text(err))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: hSizeClass == .compact ? 24 : 40) {
                        ForEach(LiveProgramCategory.allCases) { category in
                            if let programs = model.rows[category], !programs.isEmpty {
                                ProgramCategoryRow(
                                    titleKey: category.titleKey,
                                    programs: programs,
                                    tint: tint,
                                    imageURLProvider: { program in
                                        dependencies.jellyfinImageService.imageURL(
                                            itemID: program.id, serverID: program.serverID, imageType: .primary,
                                            tag: program.primaryImageTag, maxWidth: ImageWidth.wideCard)
                                    },
                                    onSelect: { program in
                                        guard let channel = model.channel(
                                            for: program, guideChannels: guideChannels)
                                        else { return }
                                        selection = ProgramSelection(channel: channel, program: program)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.vertical, hSizeClass == .compact ? 16 : 40)
                }
                #if os(iOS)
                .refreshable { await model.refresh() }
                #endif
            }
        }
        // Ungated, so the first fill never depends on the appearance callbacks below.
        .task { await model.load() }
        // Restarts whenever the rows become visible again: a returning player, a tab or section
        // switch, the app coming forward. Then it sleeps to the snapshot's own expiry rather than
        // polling, so a schedule that is not about to turn over costs nothing.
        .task(id: isWatched) {
            guard isWatched else { return }
            await model.refreshIfExpired()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.secondsUntilExpiry()))
                guard !Task.isCancelled else { return }
                await model.refreshIfExpired()
            }
        }
        // Full-screen cover, NOT .sheet: a tvOS sheet leaves the tab bar visible behind it and tvOS 26 re-templates the backgrounded bar gray. The cover covers the bar so it is never disturbed.
        .detailCover(item: $selection) { sel in
            ProgramInfoPopover(
                program: sel.program, channel: sel.channel, tint: tint,
                onWatchLive: onWatchLive,
                channelIsFavorite: timers.isFavorite(sel.channel.id),
                onToggleFavorite: { timers.toggleFavorite(channelID: sel.channel.id) },
                hasTimer: timers.effectiveTimerState(for: sel.program).timerId != nil,
                hasSeriesTimer: timers.effectiveTimerState(for: sel.program).seriesTimerId != nil,
                onToggleRecord: { timers.toggleRecord(program: sel.program) },
                onToggleSeriesRecord: { timers.toggleSeriesRecord(program: sel.program) })
            .alert(
                Text("livetv.recording.error.title"),
                isPresented: Binding(
                    get: { timers.recordingError != nil },
                    set: { if !$0 { timers.recordingError = nil } }
                )
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(timers.recordingError ?? "")
            }
        }
    }
}

/// One category row: title above a horizontal scroll of `ProgramCard`s. Mirrors `HorizontalMediaRow`.
private struct ProgramCategoryRow: View {
    let titleKey: LocalizedStringKey
    let programs: [JellyfinProgram]
    let tint: Color
    let imageURLProvider: (JellyfinProgram) -> URL?
    let onSelect: (JellyfinProgram) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.leading, metrics.rowLeading(shellPaysLeading: shellPaysLeading))
                .padding(.trailing, metrics.rowInset)

            RowScrollView(
                leading: metrics.rowLeading(shellPaysLeading: shellPaysLeading),
                trailing: metrics.rowInset,
                vertical: metrics.rowVerticalPadding
            ) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(programs) { program in
                        FocusableCard {
                            onSelect(program)
                        } content: { isFocused in
                            ProgramCard(
                                program: program,
                                imageURL: imageURLProvider(program),
                                isFocused: isFocused)
                        }
                    }
                }
            }
            .focusSectionCompat()
        }
    }
}

/// 16:9 program card (mirrors `MediaCard.landscape`, 360x202): image + TV placeholder, semantic focus
/// stroke, title + channel/time subtitle (always rendered so cards in a row stay equal height).
private struct ProgramCard: View {
    let program: JellyfinProgram
    let imageURL: URL?
    let isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // Same 16:9 family as the genre, provider and library tiles, Large Cards included.
    private var card: CGSize {
        LayoutMetrics.current(hSizeClass)
            .tileSize(cardScale: dependencies.appearancePreferences.cardScale)
    }
    private var cardWidth: CGFloat { card.width }
    private var cardHeight: CGFloat { card.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCachedImage(url: imageURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Rectangle().fill(Color.Theme.surface)
                    Image(systemName: "tv")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            .overlay(
                MediaFocusRing(
                    cornerRadius: ArtworkCorner.radius,
                    isFocused: isFocused
                )
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(program.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: cardWidth)
    }

    private var subtitle: String {
        let channel = program.channelName ?? ""
        if let start = program.startDate {
            let time = start.formatted(date: .omitted, time: .shortened)
            return channel.isEmpty ? time : "\(channel) · \(time)"
        }
        return channel.isEmpty ? " " : channel
    }
}
