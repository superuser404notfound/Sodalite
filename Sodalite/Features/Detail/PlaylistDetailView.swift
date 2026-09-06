import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var viewModel: DetailViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var showPlayer = false
    @State private var playItem: JellyfinItem?
    @State private var playQueue: [JellyfinItem] = []
    /// Value-based focus, keyed by item id, same shape as CollectionDetailView.
    @FocusState private var focusedItemID: String?
    /// Target for the up-move correction below the fold (Sodalite#53 follow-up).
    @FocusState private var playButtonFocused: Bool
    /// Overview box holds focus. The list needs no equivalent flag, focusedItemID already says it.
    @State private var overviewHasFocus = false
    /// Anything below the fold has focus, so the secondary buttons leave the focus engine and an
    /// up-move has only Play left to land on.
    private var belowFoldHasFocus: Bool { overviewHasFocus || focusedItemID != nil }
    /// One shot: no yank back to row one on every return from a film.
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
                    startFromBeginning: true,
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
        // task(id:), not onChange: the list can already be populated at first render. Same reasoning
        // as CollectionDetailView, no spinner gate.
        .task(id: viewModel?.collectionItems.count) {
            #if os(tvOS)
            guard !didFocusFirstRow, let vm = viewModel,
                  let first = videoItems(vm).first else { return }
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
                    await viewModel?.loadFullDetail()
                }
            }
        }
    }

    /// Playlist members restricted to playable video leaves; the list, count, and both play queues all read this so what's shown is exactly what Play/Shuffle enqueues.
    private func videoItems(_ vm: DetailViewModel) -> [JellyfinItem] {
        vm.collectionItems.filter { CollectionPlaybackQueue.playableTypes.contains($0.type) }
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

                if !videoItems(vm).isEmpty {
                    // No overview above it: the first row is what sits under the fold, and the page
                    // opens focused on it, so it carries the correction instead.
                    playlistList(vm: vm, correctsUpMove: !hasOverview)
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

            let count = videoItems(vm).count
            if count > 0 {
                Text("detail.collection.itemCount \(count)")
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

    /// Play starts direct sequential playback of the ordered queue, unlike
    /// CollectionDetailView whose Play navigates to the first item's detail.
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

    private func primaryActionButton(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: "detail.play",
            systemImage: "play.fill",
            isProminent: true,
            action: {
                let queue = videoItems(vm)
                guard let first = queue.first else { return }
                playItem = first
                playQueue = queue
                showPlayer = true
            }
        )
        .focused($playButtonFocused)
    }

    @ViewBuilder
    private func secondaryActionButtons(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: "action.shuffle",
            systemImage: "shuffle",
            action: {
                let queue = videoItems(vm).shuffled()
                guard let first = queue.first else { return }
                playItem = first
                playQueue = queue
                showPlayer = true
            }
        )

        GlassActionButton(
            title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
            systemImage: vm.isFavorite ? "heart.fill" : "heart",
            action: { Task { await vm.toggleFavorite() } }
        )
    }

    // MARK: - Playlist Items (vertical list)

    /// `correctsUpMove`: see CollectionDetailView, same rule.
    private func playlistList(vm: DetailViewModel, correctsUpMove: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("detail.collection.items")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            VStack(spacing: 12) {
                ForEach(Array(videoItems(vm).enumerated()), id: \.element.id) { index, media in
                    CollectionItemRow(
                        item: media,
                        imageURL: dependencies.jellyfinImageService.posterURL(for: media),
                        onSelect: { selectedItem = media }
                    )
                    .focused($focusedItemID, equals: media.id)
                    .onFocusMoveUp(active: correctsUpMove && index == 0) {
                        playButtonFocused = true
                    }
                }
            }
            .padding(.horizontal, metrics.rowInset)
        }
    }
}
