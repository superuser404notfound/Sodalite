import SwiftUI

struct CollectionDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var viewModel: DetailViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var showPlayer = false
    @State private var playItem: JellyfinItem?
    @State private var playQueue: [JellyfinItem] = []
    /// Play resumes a partially watched film; Shuffle always starts its pick from the top.
    @State private var playFromBeginning = true
    /// Value-based focus, keyed by item id: binding a per-row Bool would need a branch inside the
    /// ForEach and hand the focus engine two different view shapes for row one.
    @FocusState private var focusedItemID: String?
    /// Target for the up-move correction below the fold (Sodalite#53 follow-up).
    @FocusState private var playButtonFocused: Bool
    /// Overview box holds focus. The list needs no equivalent flag, focusedItemID already says it.
    @State private var overviewHasFocus = false
    /// Anything below the fold has focus, so the secondary buttons leave the focus engine and an
    /// up-move has only Play left to land on.
    private var belowFoldHasFocus: Bool { overviewHasFocus || focusedItemID != nil }
    /// One shot: re-pushing focus on every appear would yank the viewer back to row one after
    /// every return from a film or a pushed detail page.
    @State private var didFocusFirstRow = false

    let item: JellyfinItem

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                contentView(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(when: !isPhonePortrait)
        .hidesToolbarBackground()
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? playItem : nil,
                    startFromBeginning: playFromBeginning,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: userID),
                    cachedPlaybackInfo: nil,
                    preferredMediaSourceID: nil,
                    playQueue: playQueue
                )
                .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        .navigationDestination(item: $selectedItem) { item in
            DetailRouterView(item: item)
                .detailCoverPush()
        }
        // task(id:), not onChange: the list can already be populated when this view first renders
        // (warm cache), and onChange only sees transitions. No spinner gate here on purpose: isLoading
        // flips at a 500ms snapshot deadline and hasFullDetail can take 10s+ on a slow library, so
        // gating the view on either would reinstate the wait Sodalite#15 removed.
        //
        // The list shows every member while Play filters to playable leaves, so focus follows the
        // list's first row, not the queue's.
        .task(id: viewModel?.collectionItems.count) {
            #if os(tvOS)
            guard !didFocusFirstRow, let first = viewModel?.collectionItems.first else { return }
            didFocusFirstRow = true
            deferOnMain(by: 0.1) { focusedItemID = first.id }
            #endif
        }
        .onAppear {
            if viewModel == nil, let userID = appState.activeUser?.id {
                viewModel = DetailViewModel(
                    item: item,
                    itemService: dependencies.jellyfinItemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    playbackService: dependencies.jellyfinPlaybackService
                )
                Task {
                    // loadFullDetail loads collection items internally for .boxSet; a separate loadCollectionItems would be a redundant round trip.
                    await viewModel?.loadFullDetail()
                }
            }
        }
    }

    private func contentView(vm: DetailViewModel) -> some View {
        ZStack {
            DetailBackdrop(
                imageURL: vm.backdropURL(for: vm.item),
                posterFallbackURL: vm.heroPosterURL(for: vm.item)
            )
            .ignoresSafeArea()

            DetailContentOverlay(
                heroImageURL: vm.backdropURL(for: vm.item),
                heroPosterURL: vm.heroPosterURL(for: vm.item),
                primary: {
                // Glass panel + action buttons as the bottom-aligned first-page block, matching movie/series detail (Sodalite#15 round 6).
                VStack(alignment: .leading, spacing: 24) {
                    glassPanel(vm: vm)
                    actionButtonRow(vm: vm)
                }
                .padding(.horizontal, metrics.rowInset)
            }) {
                let hasOverview = !(vm.item.overview?.isEmpty ?? true)
                if let overview = vm.item.overview, !overview.isEmpty {
                    // Up out of the box lands on the row's last button unless corrected (Sodalite#53).
                    ExpandableTextBox(
                        text: overview,
                        onFocusMovedUp: { playButtonFocused = true },
                        onFocusChanged: { overviewHasFocus = $0 }
                    )
                    .padding(.horizontal, metrics.rowInset)
                }

                if !vm.collectionItems.isEmpty {
                    // With no overview above it the first row is what sits under the fold, and the
                    // page opens focused on it, so it carries the correction instead.
                    collectionList(vm: vm, correctsUpMove: !hasOverview)
                }
            }
        }
    }

    // MARK: - Glass Panel

    private func glassPanel(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(vm.item.name)
                .font(.largeTitle)
                .fontWeight(.bold)

            if !vm.collectionItems.isEmpty {
                Text("detail.collection.itemCount \(vm.collectionItems.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Button row directly below the glass panel, outside the plate,
    /// matching the movie and series detail views.
    private func actionButtonRow(vm: DetailViewModel) -> some View {
        Group {
            if isPhonePortrait {
                VStack(spacing: 12) {
                    primaryActionButton(vm: vm)
                        .frame(maxWidth: .infinity)
                    DetailActionRow(alignment: .center, balanced: true) {
                        secondaryActionButtons(vm: vm)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                DetailActionRow {
                    primaryActionButton(vm: vm)
                    secondaryActionButtons(vm: vm)
                        .focusSuppressed(belowFoldHasFocus)
                }
            }
        }
    }

    /// Plays the first unfinished film and queues the rest behind it. Until Sodalite#53 this
    /// navigated to the first item's detail page, duplicating its own first list row.
    private func primaryActionButton(vm: DetailViewModel) -> some View {
        let queue = playableItems(vm: vm)
        let start = CollectionPlaybackQueue.startIndex(
            playedFlags: queue.map { $0.userData?.played == true }
        )
        return GlassActionButton(
            title: "detail.play",
            systemImage: "play.fill",
            isProminent: true,
            subtitle: queue.indices.contains(start) ? queue[start].name : nil,
            action: {
                guard queue.indices.contains(start) else { return }
                playItem = queue[start]
                playQueue = Array(queue[start...])
                playFromBeginning = false
                showPlayer = true
            }
        )
        .focused($playButtonFocused)
    }

    /// Members already loaded; filtered to playable leaf types so a nested series can't seed an
    /// unplayable queue entry.
    private func playableItems(vm: DetailViewModel) -> [JellyfinItem] {
        vm.collectionItems.filter { CollectionPlaybackQueue.playableTypes.contains($0.type) }
    }

    @ViewBuilder
    private func secondaryActionButtons(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: "action.shuffle",
            systemImage: "shuffle",
            action: {
                let queue = playableItems(vm: vm).shuffled()
                guard let first = queue.first else { return }
                playItem = first
                playQueue = queue
                playFromBeginning = true
                showPlayer = true
            }
        )

        GlassActionButton(
            title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
            systemImage: vm.isFavorite ? "heart.fill" : "heart",
            action: { Task { await vm.toggleFavorite() } }
        )
    }

    // MARK: - Collection Items (vertical list)

    /// `correctsUpMove` sends the first row's up-move back to Play; only set when no overview box
    /// sits between the row and the button row, which would otherwise become unreachable.
    private func collectionList(vm: DetailViewModel, correctsUpMove: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("detail.collection.items")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            VStack(spacing: 12) {
                ForEach(Array(vm.collectionItems.enumerated()), id: \.element.id) { index, movie in
                    CollectionItemRow(
                        item: movie,
                        imageURL: dependencies.jellyfinImageService.posterURL(for: movie),
                        onSelect: { selectedItem = movie }
                    )
                    .focused($focusedItemID, equals: movie.id)
                    .onFocusMoveUp(active: correctsUpMove && index == 0) {
                        playButtonFocused = true
                    }
                }
            }
            .padding(.horizontal, metrics.rowInset)
        }
    }
}

// MARK: - Collection Item Row

struct CollectionItemRow: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass

    let item: JellyfinItem
    let imageURL: URL?
    let onSelect: () -> Void

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    private var overview: String? {
        guard let overview = item.overview, !overview.isEmpty else { return nil }
        return overview
    }

    /// Three overview lines fill the poster height, so the text block tops out next to it.
    /// Without an overview the block is too short for that and stays centered.
    static func verticalAlignment(hasOverview: Bool) -> VerticalAlignment {
        hasOverview ? .top : .center
    }

    var body: some View {
        Button { onSelect() } label: {
            HStack(alignment: Self.verticalAlignment(hasOverview: overview != nil), spacing: 20) {
                AsyncCachedImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.Theme.surface)
                }
                .frame(width: metrics.listPosterSize.width, height: metrics.listPosterSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(metrics.listTitleFont)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    // Values must stay atomic on the narrow phone row: the flow layout wraps whole
                    // chips to a second line instead of shrinking them past legibility or breaking
                    // mid-token ("7.0" -> "7."/"0", "74 %" -> "74"/"%").
                    FlowLayout(spacing: 10) {
                        if let year = item.productionYear {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let runtime = item.runTimeTicks {
                            Text(runtime.ticksToDisplay)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let score = item.communityRating {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption2)
                                Text(String(format: "%.1f", score))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                        }
                        // RT critic score, fresh/rotten split at 60; only when the server delivers CriticRating.
                        if let critic = item.criticRating {
                            HStack(spacing: 3) {
                                Image(critic >= 60 ? "RTFresh" : "RTRotten")
                                    .resizable()
                                    .renderingMode(.original)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 16)
                                Text(verbatim: "\(Int(critic)) %")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                        }
                    }

                    if let overview {
                        Text(overview)
                            .font(metrics.listOverviewFont)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                    }
                }

                Spacer()

                if item.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Theme.success)
                } else if let pct = item.userData?.playedPercentage, pct > 0 {
                    Text("\(Int(pct))%")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .padding(16)
        }
        .buttonStyle(CollectionRowButtonStyle())
    }
}

struct CollectionRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    // Glass material resting background on both platforms so the row text stays readable over a
    // bright poster backdrop (matching the detail bubbles). tvOS layers the focus-driven white
    // brighten on top; on iOS there is no focus engine so the overlay stays invisible.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isFocused ? 0.12 : 0))
            )
    }
}
