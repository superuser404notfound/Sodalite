import SwiftUI

struct MovieDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var viewModel: DetailViewModel?
    @State private var navigateToSeries: JellyfinItem?
    @State private var navigateToItem: JellyfinItem?
    @State private var navigateToPerson: PersonRoute?
    /// Catalog similar row target; the series page has carried the same destination since the Seerr request button.
    @State private var navigateToSeerrRequest: SeerrMedia?
    @State private var showPlayer = false
    @State private var playFromBeginning = false
    @State private var versionChoice: VersionPickerChoice?
    @State private var pendingSourceID: String?
    /// Latched on an actual version pick so the sheet's onDismiss launches the player on a pick but not a cancel.
    @State private var didPickVersion = false
    @State private var showTrailer = false
    @State private var trailerItem: JellyfinItem?
    @State private var isPresentingDeleteSheet: Bool = false
    @FocusState private var playButtonFocused: Bool
    /// Overview box below the fold holds focus: the secondary buttons leave the focus engine for
    /// that time so an up-move can only land on Play (Sodalite#53 follow-up).
    @State private var overviewHasFocus = false
    /// Gates the isLoading crossfade so it stays inert during the cover's present transition. The viewModel is built lazily in onAppear, so isLoading flips several times (nil->false->true->false) WHILE the fullScreenCover is dissolving in; animating those flips interpolates the content's not-yet-laid-out frame (origin top-left) and reads as an ugly fly-in. Enabled ~0.35s after appear so the later, deliberate slow-server spinner->content fade still animates.
    @State private var didSettleIn = false

    let item: JellyfinItem
    /// TopShelf playAction: fire the primary play action once, as soon as full detail has settled.
    var autoPlay: Bool = false
    @State private var didAutoPlay = false

    /// EnableContentDeletion (or admin) on the active user; read reactively from AppState.activeUser so a profile switch updates visibility without a manual refresh.
    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }

    /// Seerr service for the catalog similar row, nil while the Catalog tab is hidden: switching it off is a parental measure (Sodalite#62), so the catalog has to be gone here as well, exactly as in Search and on person pages.
    private var catalogSimilarService: SeerrMediaServiceProtocol? {
        dependencies.appearancePreferences.isTabHidden(.catalog) ? nil : dependencies.seerrMediaService
    }

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    /// iPhone portrait: stacked, poster-hero detail with a full-width primary action over a collapsed secondary row.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass == .regular
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            // Solid black under the loading state (contentView paints its own backdrop), see SeriesDetailView.
            Color.black.ignoresSafeArea()

            if let vm = viewModel, !vm.isLoading {
                contentView(vm: vm)
                    .transition(.opacity)
            } else {
                // Centred spinner; gating on isLoading lands one finished frame instead of a field-fill repaint (SeriesDetailView rationale).
                ZStack {
                    ProgressView()
                    // Invisible focus anchor so a Menu press during load pops back instead of quitting the app.
                    Button("") { dismiss() }
                        .opacity(0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .animation(didSettleIn ? .easeInOut(duration: 0.25) : nil, value: viewModel?.isLoading)
        // iPhone portrait respects the safe area so detail content is not clipped under the status
        // bar; the backdrop keeps its own .ignoresSafeArea() to stay full-bleed. tvOS/iPad full-bleed.
        .ignoresSafeArea(when: !isPhonePortrait)
        .hidesToolbarBackground()
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? (viewModel?.item ?? item) : nil,
                    startFromBeginning: playFromBeginning,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: userID),
                    cachedPlaybackInfo: viewModel?.cachedPlaybackInfo,
                    preferredMediaSourceID: pendingSourceID
                )
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showTrailer,
                    item: showTrailer ? trailerItem : nil,
                    startFromBeginning: true,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: userID),
                    // Trailer is a distinct server item; the movie's
                    // cached PlaybackInfo does not apply to it.
                    cachedPlaybackInfo: nil
                )
                .allowsHitTesting(false)
            }
        }
        // task(id:), NOT onChange: onChange only sees transitions. On a cold launch the deep-link
        // resolver waits for the session and fetches the item first, so by the time this view
        // renders the detail can already be complete, and there is no transition left to observe.
        // task(id:) runs once for the initial value too.
        //
        // hasFullDetail, not isLoading: isLoading flips nil->false->true->false and that first
        // false precedes the detail round trip, so requestPlay would see mediaSources still nil
        // and skip the version picker for a multi-version movie.
        .task(id: viewModel?.hasFullDetail) {
            guard autoPlay, !didAutoPlay, viewModel?.hasFullDetail == true,
                  let vm = viewModel else { return }
            didAutoPlay = true
            requestPlay(fromBeginning: false, vm: vm)
        }
        .sheet(item: $versionChoice, onDismiss: {
            if didPickVersion {
                didPickVersion = false
                // The detail view is itself a fullScreenCover (9ac00b32), so the version-picker sheet and
                // the player modal share its single presentedViewController slot. PlayerLauncher now waits
                // for the sheet's dismissal transition to finish before presenting (a fixed delay raced it
                // on slow hardware, #31), so just request the player here.
                showPlayer = true
            }
        }) { choice in
            VersionPickerSheet(
                sources: choice.sources,
                tintColor: dependencies.appearancePreferences.effectiveTint(
                    isSupporter: dependencies.storeKitService.isSupporter
                )
            ) { source in
                pendingSourceID = source.id
                playFromBeginning = choice.fromBeginning
                didPickVersion = true
                versionChoice = nil
            }
        }
        .onChange(of: showTrailer) { _, isPlaying in
            if !isPlaying {
                trailerItem = nil
                deferOnMain(by: 0.1) { playButtonFocused = true }
            }
        }
        .onChange(of: showPlayer) { _, isPlaying in
            if !isPlaying {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        // The player continued on the item that replaced this one (a Radarr upgrade rewrote the file, so
        // the library minted a new id). Swap it in, else this screen keeps describing the file that is
        // gone and its Play button keeps launching into the dead id.
        .onReceive(NotificationCenter.default.publisher(for: .libraryItemDidReplace)) { note in
            guard let staleID = note.userInfo?[LibraryItemReplacementKey.staleID] as? String,
                  staleID == item.id,
                  let replacement = note.userInfo?[LibraryItemReplacementKey.item] as? JellyfinItem else { return }
            viewModel?.applyItemReplacement(staleID: staleID, newItem: replacement)
        }
        // Posted once Jellyfin confirms the stop position. Patch in place from the payload (race-free); refreshResumePosition only reconciles played/favorite, then the patch is re-applied so a stale cached re-fetch can't regress the just-played position (issue #24).
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { note in
            let itemID = note.userInfo?[PlaybackProgressKey.itemID] as? String
            let ticks = note.userInfo?[PlaybackProgressKey.positionTicks] as? Int64
            Task { @MainActor in
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                await viewModel?.refreshResumePosition()
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
            }
        }
        // AppRouter bumps this on every deep-link arrival so a TopShelf tap on a different item tears down the active player session and surfaces the new detail sheet cleanly.
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        // Play button is out of the tree at first paint; push focus once isLoading flips false. Tiny defer dodges the focus-commit race.
        .onChange(of: viewModel?.isLoading) { _, loading in
            if loading == false {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        .navigationDestination(item: $navigateToSeerrRequest) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .navigationDestination(item: $navigateToItem) { item in
            DetailRouterView(item: item)
                .detailCoverPush()
        }
        .navigationDestination(item: $navigateToSeries) { series in
            SeriesDetailView(item: series)
                .hidesShellTabBar()
                .detailCoverPush()
        }
        .navigationDestination(item: $navigateToPerson) { route in
            PersonDetailView(
                personID: route.tmdbID,
                jellyfinPersonID: route.jellyfinPersonID,
                personName: route.name
            )
                .detailCoverPush()
        }
        .onAppear {
            if viewModel == nil, let userID = appState.activeUser?.id {
                viewModel = DetailViewModel(
                    item: item,
                    itemService: dependencies.jellyfinItemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    libraryService: dependencies.jellyfinLibraryService,
                    playbackService: dependencies.jellyfinPlaybackService,
                    seerrMediaService: catalogSimilarService
                )
                Task { await viewModel?.loadFullDetail() }
            }
            // Open the animation gate once the cover's present transition has settled.
            deferOnMain(by: 0.35) { didSettleIn = true }
        }
        .sheet(isPresented: $isPresentingDeleteSheet) {
            if let vm = viewModel {
                let popDetail = dismiss
                MediaDeletionSheet(
                    mode: .movie(
                        itemID: vm.item.id,
                        tmdbID: vm.item.tmdbID,
                        title: vm.item.name
                    ),
                    onConfirm: { request in
                        do {
                            try await dependencies.mediaDeletionService.deleteMovie(
                                itemID: vm.item.id,
                                tmdbID: vm.item.tmdbID,
                                cascadeToArrStack: request.cascadeToArrStack
                            )
                            // Drop the on-disk filter cache so Library/Home rows don't keep showing the deleted movie until natural eviction. Every profile on this server, not just the active one: the file is gone for all of them.
                            if let serverID = appState.activeServer?.id {
                                FilterCache.shared.evict(serverID: serverID)
                            }
                            NotificationCenter.default.post(name: .homeItemDidDelete, object: nil)
                            // The cascade also cleared the title's open Seerr requests, so the request lists are stale.
                            if request.cascadeToArrStack {
                                NotificationCenter.default.post(name: .seerrRequestsDidChange, object: nil)
                            }
                            // Pop after the sheet's success-toast hold.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(1100))
                                popDetail()
                            }
                            return .success
                        } catch {
                            return .from(error)
                        }
                    }
                )
            }
        }
    }

    private func contentView(vm: DetailViewModel) -> some View {
        ZStack {
            DetailBackdrop(
                imageURL: vm.backdropURL(for: vm.item),
                posterFallbackURL: vm.heroPosterURL(for: vm.item)
            )
                .id(vm.item.backdropImageTags?.first ?? "empty")
                .ignoresSafeArea()

            DetailContentOverlay(
                heroImageURL: vm.backdropURL(for: vm.item),
                heroPosterURL: vm.heroPosterURL(for: vm.item),
                hero: {
                DetailHeroLogo(viewModel: vm)
            }, primary: {
                // Glass panel + action buttons as the bottom-aligned first-page block (Sodalite#15 round 6), mirroring SeriesDetailView.
                VStack(alignment: .leading, spacing: 24) {
                    glassPanel(vm: vm)
                    actionButtonRow(vm: vm)
                }
                .padding(.horizontal, metrics.rowInset)
            }) {
                if let overview = vm.item.overview, !overview.isEmpty {
                    // Coming back up from the overview lands on the row's last button, Delete, unless
                    // it is corrected: the engine resolves the move from the box's centre (Sodalite#53).
                    ExpandableTextBox(
                        text: overview,
                        spoilerItem: vm.item,
                        onFocusMovedUp: { playButtonFocused = true },
                        onFocusChanged: { overviewHasFocus = $0 }
                    )
                    .padding(.horizontal, metrics.rowInset)
                } else if !vm.hasFullDetail {
                    // Overview in flight after a snapshot paint: reserve the footprint (Sodalite#15).
                    ExpandableTextBoxPlaceholder()
                        .padding(.horizontal, metrics.rowInset)
                }

                // Cast ahead of the tech strip (Sodalite#47): the four tech cards cost about a
                // screen third, so the cast row was several remote presses down for viewers who
                // only want the people. Codec details stay one row further for those who want them.
                if let people = vm.item.people, !people.isEmpty {
                    MediaCastRow(
                        members: jellyfinCastMembers(
                            from: people,
                            imageService: dependencies.jellyfinImageService,
                            imageWidth: metrics.castImageWidth
                        ),
                        onSelect: { handlePersonTap($0) }
                    )
                }

                if vm.item.mediaStreams != nil || vm.item.mediaSources != nil {
                    TechInfoBox(item: vm.item)
                }

                if !vm.similarItems.isEmpty {
                    HorizontalMediaRow(
                        title: "detail.similar",
                        items: vm.similarItems,
                        imageURLProvider: { vm.posterURL(for: $0) },
                        onItemSelected: { navigateToItem = $0 },
                        cardStyle: .poster
                    )
                }

                // Same split the search screen teaches: what the server has on top, what it would have
                // to fetch below, under the header the catalog already uses.
                if !vm.catalogSimilar.isEmpty {
                    SeerrHorizontalMediaRow(
                        title: "search.section.catalog",
                        items: vm.catalogSimilar,
                        onItemSelected: { navigateToSeerrRequest = $0 }
                    )
                }
            }
        }
    }

    // MARK: - Glass Panel

    private func glassPanel(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title/logo lives in the hero slot (see DetailContentOverlay); panel opens into the metadata row.
            if vm.item.type == .episode, let series = vm.item.seriesName {
                Text(episodeSubtitle(vm: vm, seriesName: series))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Metadata+tagline row one, genres+credits row two, baseline-aligned so columns sit level.
            DetailInfoRows(
                item: vm.item,
                hasFullDetail: vm.hasFullDetail,
                hasLeftSecondary: !(vm.item.genres?.isEmpty ?? true),
                leftSecondaryPending: !vm.hasFullDetail && vm.item.genres == nil
            ) {
                ItemMetadataRow(item: vm.item)
            } leftSecondary: {
                if let genres = vm.item.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Version picker vs direct start; movies carry their media sources from the detail fetch, so the count check is reliable.
    private func requestPlay(fromBeginning: Bool, vm: DetailViewModel) {
        if let sources = vm.item.mediaSources, sources.count > 1 {
            versionChoice = VersionPickerChoice(
                item: vm.item,
                sources: sources,
                fromBeginning: fromBeginning,
                fromPlayButton: false
            )
        } else {
            playFromBeginning = fromBeginning
            pendingSourceID = nil
            showPlayer = true
        }
    }

    // MARK: - Action Buttons

    /// Button row below the glass panel, outside it (Sodalite#15 round 6); each GlassActionButton carries its own material so the row needs no plate.
    /// iPhone portrait stacks a full-width primary action over a collapsed secondary row; other layouts keep the single scrollable row.
    private func actionButtonRow(vm: DetailViewModel) -> some View {
        Group {
            if isPhonePortrait {
                VStack(spacing: 12) {
                    primaryActionButton(vm: vm)
                        .frame(maxWidth: .infinity)
                    // Centered, and wrapping to a second line rather than scrolling.
                    DetailActionRow(alignment: .center, balanced: true) {
                        secondaryActionButtons(vm: vm)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                DetailActionRow {
                    primaryActionButton(vm: vm)
                    secondaryActionButtons(vm: vm)
                        .focusSuppressed(overviewHasFocus)
                }
            }
        }
    }

    private func primaryActionButton(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: playButtonTitle(vm: vm),
            systemImage: "play.fill",
            isProminent: true,
            subtitle: resumeTimestamp(vm: vm),
            progressFraction: playProgressFraction(vm: vm),
            action: {
                requestPlay(fromBeginning: false, vm: vm)
            }
        )
        .focused($playButtonFocused)
    }

    @ViewBuilder
    private func secondaryActionButtons(vm: DetailViewModel) -> some View {
        if hasProgress(vm: vm) {
                GlassActionButton(
                    title: "detail.replay",
                    systemImage: "arrow.counterclockwise",
                    action: {
                        requestPlay(fromBeginning: true, vm: vm)
                    }
                )
            }

            if vm.hasLocalTrailer {
                GlassActionButton(
                    title: "detail.trailer",
                    systemImage: "play.rectangle",
                    action: {
                        Task {
                            if let trailer = await vm.loadTrailer() {
                                trailerItem = trailer
                                showTrailer = true
                            }
                        }
                    }
                )
            }

            if vm.item.type != .episode {
                GlassActionButton(
                    title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                    action: { Task { await vm.toggleFavorite() } }
                )
            }

            if vm.item.type == .episode, let seriesId = vm.item.seriesId {
                GlassActionButton(
                    title: "detail.showSeries",
                    systemImage: "tv",
                    action: {
                        navigateToSeries = JellyfinItem(
                            seriesStub: seriesId,
                            name: vm.item.seriesName ?? ""
                        )
                    }
                )
            }

            // No "Request in Seerr" on movie detail: the movie is already in Jellyfin. The button stays on series detail for continuing shows.

            GlassActionButton(
                title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                action: { Task { await vm.togglePlayed() } }
            )

            // Episodes only reach here via DetailRouterView's no-parent-series fallback; per-episode deletion isn't supported (delete lives on series detail, matching SeriesDetailView's !isShowingEpisode guard).
            if canDelete && item.type != .episode {
                GlassActionButton(
                    title: "detail.delete.button",
                    systemImage: "trash",
                    isDestructive: true,
                    action: { isPresentingDeleteSheet = true }
                )
            }
    }

    // MARK: - Helpers

    private func hasProgress(vm: DetailViewModel) -> Bool {
        if let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0 { return true }
        return false
    }

    private func playButtonTitle(vm: DetailViewModel) -> LocalizedStringKey {
        if hasProgress(vm: vm) { return "detail.resume" }
        return "detail.play"
    }

    /// Formatted resume timestamp for the play-button subtitle, or nil when there's nothing to resume (fresh or finished).
    private func resumeTimestamp(vm: DetailViewModel) -> String? {
        guard let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0 else {
            return nil
        }
        return ResumeTimeFormatter.format(ticks: ticks)
    }

    /// 0…1 progress for the play button's overlay; nil when fresh or no run-time metadata.
    private func playProgressFraction(vm: DetailViewModel) -> Double? {
        guard let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0,
              let total = vm.item.runTimeTicks, total > 0 else {
            return nil
        }
        return min(1.0, max(0.0, Double(ticks) / Double(total)))
    }

    private func episodeSubtitle(vm: DetailViewModel, seriesName: String) -> String {
        EpisodeMetadataFormatter.label(seriesName: seriesName,
                                       season: vm.item.parentIndexNumber,
                                       episode: vm.item.indexNumber,
                                       title: nil)
    }

    /// Resolve a cast member to a TMDB person id and open the person page; inert when the server has no TMDB id.
    private func handlePersonTap(_ member: CastMember) {
        navigateToPerson = PersonRoute(member: member)
    }
}
