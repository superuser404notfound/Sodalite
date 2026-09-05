import SwiftUI

struct SeriesDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var viewModel: DetailViewModel?
    @State private var selectedEpisode: JellyfinItem?
    /// Episode IDs whose enrichedEpisode fetch settled; gates the episode-mode synopsis placeholder so an overview-less episode collapses the box instead of reserving it forever.
    @State private var settledEpisodeDetailIDs: Set<String> = []
    @State private var navigateToItem: JellyfinItem?
    @State private var navigateToPerson: PersonRoute?
    @State private var navigateToSeerrRequest: SeerrMedia?
    @State private var backdropURL: URL?
    @State private var showPlayer = false
    @State private var playQueue: [JellyfinItem] = []
    @State private var playItem: JellyfinItem?
    @State private var playFromBeginning = false
    @State private var versionChoice: VersionPickerChoice?
    @State private var pendingSourceID: String?
    @State private var didPickVersion = false
    /// Play launched from the glass-panel Play button vs an episode card; player-dismiss restores focus to the right control (else Down jumped past the seasons row to cast).
    @State private var playOriginatedFromPlayButton = false
    @State private var isShuffleLoading = false
    /// Outer vertical ScrollView proxy; player-dismiss scrolls back to the episode row else the nil-flicker focus restore leaves the page stuck at the top.
    @State private var episodeRowScrollProxy: ScrollViewProxy?
    /// Whole-page scroll proxy, iOS only (see PageScrollProxyCapture). Captured outside DetailContentOverlay so it can reach the glass panel, which sits above the content block episodeRowScrollProxy covers.
    @State private var pageScrollProxy: ScrollViewProxy?
    /// Scroll target on the glass panel; "Show Details" brings the episode panel into view with it.
    private static let pageTopAnchor = "detailPageTop"
    @FocusState private var focusedSeasonID: String?
    @FocusState private var focusedEpisodeID: String?
    @FocusState private var focusBridgeActive: Bool
    /// Play button enters the hierarchy only after isLoading flips false, so the focus engine has nothing to auto-land on at first paint; pushed explicitly via .onChange below.
    @FocusState private var playButtonFocused: Bool
    /// Overview box below the fold holds focus: the secondary buttons leave the focus engine for
    /// that time so an up-move can only land on Play (Sodalite#53 follow-up).
    @State private var overviewHasFocus = false
    @State private var isPresentingDeleteSheet: Bool = false
    /// Set on episode "Show Details": the context menu restores focus to its anchor card on dismiss, so the focusedEpisodeID observer bounces focus up to the play button.
    @State private var pendingPlayFocusAfterMenu = false

    /// Seerr service for the catalog similar row, nil while the Catalog tab is hidden: switching it off is a parental measure (Sodalite#62), so the catalog has to be gone here as well, exactly as in Search and on person pages.
    private var catalogSimilarService: SeerrMediaServiceProtocol? {
        dependencies.appearancePreferences.isTabHidden(.catalog) ? nil : dependencies.seerrMediaService
    }

    /// EnableContentDeletion (or admin) on the active user; read reactively from AppState.activeUser so a profile switch updates visibility without a manual refresh.
    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    /// iPhone portrait: full-width primary action over a centered secondary row.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    private func deletionSeasonOptions(from seasons: [JellyfinItem]) -> [MediaDeletionSheet.SeasonOption] {
        seasons.map { season in
            MediaDeletionSheet.SeasonOption(
                id: season.id,
                seasonNumber: season.indexNumber ?? 0,
                title: season.name
            )
        }
    }

    @State private var episodeRedirectDone = false
    /// Sticky: set when the episode row had focus so the season bar's onChange distinguishes "scrolled up from episodes" from "tabbing between tabs" and snaps focus back to the playing season (else tvOS lands on whichever tab is geographically above the last episode).
    @State private var episodesHadFocus = false
    /// Last focused region in the season+episode block; the focus bridge reads it to tell which direction a cross-row jump came from without inspecting @FocusState (already nil mid-transition).
    @State private var lastFocusedArea: FocusArea = .none
    private enum FocusArea { case none, season, episode }
    /// Bridge season→episode writes the target episode id here; the episode-row ScrollViewReader scrolls it into the LazyHStack then writes focusedEpisodeID, since a focusedEpisodeID write for an unrendered card is a silent no-op (right-side-takes-two-clicks case).
    @State private var pendingEpisodeFocus: String?
    /// Bridge episode→season synopsis. Plain @State for the same reason as pendingEpisodeFocus: the box owns its own @FocusState and defers the write itself.
    @State private var pendingSeasonOverviewFocus = false
    /// Which card the episode row aims at, so a return from above lands there instead of scrolling the row back to the start. Fed by the way OUT of the row and by the player's in-session item switches; see EpisodeRowAim for why it is never fed on the way in.
    @State private var episodeAim = EpisodeRowAim()
    /// Horizontal offset of the episode row, so a season switch can return it to the row's real start (its inset included) instead of to the first card's leading edge.
    @State private var episodeRowPosition = ScrollPosition()
    /// Gates the isLoading crossfade so it stays inert during the cover's present transition (the viewModel is built lazily in onAppear, so isLoading flips while the fullScreenCover dissolves in and animating those flips reads as an ugly top-left fly-in). Same fix as MovieDetailView.
    @State private var didSettleIn = false

    let item: JellyfinItem
    /// Seeds the preselected episode for an episode-route open (DetailRouterView .episode) so the panel paints from snapshot and the VM lands on the right season. nil for a normal series open.
    var initialEpisode: JellyfinItem? = nil
    /// TopShelf playAction: fire the primary play action once, as soon as a play target exists.
    var autoPlay: Bool = false
    @State private var didAutoPlay = false
    /// Play was pressed while the target was still resolving; the target-keyed task honours it on arrival.
    @State private var pendingPlayRequest = false

    /// Re-keys the autoplay task whenever the resolved play target changes, so it also runs for
    /// whatever target already exists at first render. `autoPlay` is part of the key because the
    /// flag can arrive after the target does, and that late arrival has to re-run the check.
    private var autoPlayTargetKey: String {
        guard let vm = viewModel else { return "\(autoPlay)-no-vm" }
        return "\(autoPlay)-\(playTarget(vm: vm)?.id ?? "no-target")"
    }

    /// Gated on playTarget rather than hasFullDetail: the latter describes the series, not whether a playable episode has been resolved yet.
    private func maybeAutoPlay() {
        guard autoPlay, !didAutoPlay, let vm = viewModel,
              let target = playTarget(vm: vm) else { return }
        didAutoPlay = true
        requestPlay(target, fromBeginning: false, fromPlayButton: true)
    }

    /// Honour a Play press that arrived while the target was still resolving. Same key as autoplay, so it runs the moment getNextUp lands.
    private func maybePendingPlay() {
        guard pendingPlayRequest, !showPlayer, versionChoice == nil,
              let vm = viewModel, let target = playTarget(vm: vm) else { return }
        pendingPlayRequest = false
        requestPlay(target, fromBeginning: false, fromPlayButton: true)
    }

    /// `fromPlayButton` preserves the focus-restoration origin flag the trigger sites set.
    private func requestPlay(_ episode: JellyfinItem, fromBeginning: Bool, fromPlayButton: Bool) {
        // Ordinary play is never a shuffle queue; drop any queue a prior
        // shuffle launch left behind so the launcher reuses single-item play.
        playQueue = []
        if let sources = episode.mediaSources, sources.count > 1 {
            versionChoice = VersionPickerChoice(
                item: episode,
                sources: sources,
                fromBeginning: fromBeginning,
                fromPlayButton: fromPlayButton
            )
        } else {
            playItem = episode
            playFromBeginning = fromBeginning
            playOriginatedFromPlayButton = fromPlayButton
            pendingSourceID = nil
            showPlayer = true
        }
    }

    private var displayItem: JellyfinItem {
        selectedEpisode ?? viewModel?.item ?? item
    }

    private var isShowingEpisode: Bool {
        selectedEpisode != nil
    }

    /// Synopsis overview. Slim-sourced episodes (Home/search) lack Overview until the detail fetch backfills it (seconds late on slow CDNs), so fall back to the matching episode-list entry (carries Overview) and the synopsis paints with the episode row (Sodalite#15).
    private var displayOverview: String? {
        if let overview = displayItem.overview, !overview.isEmpty {
            return overview
        }
        if let id = selectedEpisode?.id,
           let match = viewModel?.episodes.first(where: { $0.id == id }),
           let overview = match.overview, !overview.isEmpty {
            return overview
        }
        return nil
    }

    var body: some View {
        ZStack {
            // Solid black behind the spinner; backdrop held back until content is ready to crossfade over it.
            Color.black.ignoresSafeArea()

            if let vm = viewModel, !vm.isLoading {
                DetailBackdrop(
                    imageURL: backdropURL,
                    posterFallbackURL: vm.heroPosterURL(for: vm.item)
                )
                    .id(backdropURL?.absoluteString ?? "empty")
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            if let vm = viewModel, !vm.isLoading {
                DetailContentOverlay(
                    heroImageURL: backdropURL,
                    heroPosterURL: vm.heroPosterURL(for: vm.item),
                    hero: {
                    // Series logo, both modes (episode has none); observes the VM so it appears once an episode deep-link's series stub loads imageTags, no scroll needed.
                    DetailHeroLogo(viewModel: vm)
                }, primary: {
                    // Glass panel + action buttons as the bottom-aligned first-page block (Sodalite#15 round 6), kept one unit so the id-rebuild and episode crossfade cover both.
                    VStack(alignment: .leading, spacing: 24) {
                        glassPanel(vm: vm)
                            .id(Self.pageTopAnchor)
                        actionButtonRow(vm: vm)
                    }
                    .padding(.horizontal, metrics.rowInset)
                    // Keyed on item + load state only, NOT genre count: on an instant-paint episode deep-link the series genres land post-paint, flipping the count rebuilt the panel and broke scroll-to-top back to Play. Genres fill in via in-place diff.
                    .id("\(vm.item.id)-\(vm.isLoading)")
                    .animation(.easeInOut(duration: 0.3), value: selectedEpisode?.id)
                }) {
                    // Captured proxy lets player-dismiss scroll the outer ScrollView back to the episode row, else tvOS's scroll-focus-into-view runs against a not-yet-rendered state and jumps to the top.
                    ScrollViewReader { outerProxy in
                        VStack(alignment: .leading, spacing: 40) {
                            // Navigable synopsis box, both modes; a top-level item keyed on item id renders reliably on data-land, unlike an in-panel teaser the ScrollView left blank until a scroll.
                            if let overview = displayOverview {
                                // displayItem is the series in series mode and the selected episode
                                // in episode mode, so the series overview stays visible (the policy
                                // ignores .series) while the episode overview is veiled.
                                // Up out of the box lands on the row's last button, Delete, unless it
                                // is corrected: the engine resolves it from the box's centre (Sodalite#53).
                                ExpandableTextBox(
                                    text: overview,
                                    spoilerItem: displayItem,
                                    onFocusMovedUp: { playButtonFocused = true },
                                    onFocusChanged: { overviewHasFocus = $0 }
                                )
                                .padding(.horizontal, metrics.rowInset)
                                .id(displayItem.id)
                            } else if !isShowingEpisode && !vm.hasFullDetail {
                                // Slim-snapshot paint, overview in flight: reserve the footprint so it doesn't pop in and shove the season row down (Sodalite#15).
                                ExpandableTextBoxPlaceholder()
                                    .padding(.horizontal, metrics.rowInset)
                            } else if isShowingEpisode, let ep = selectedEpisode,
                                      ep.mediaStreams == nil, ep.mediaSources == nil,
                                      !settledEpisodeDetailIDs.contains(ep.id) {
                                // Episode-mode slim snapshot, overview may still land (Sodalite#15). The mediaStreams/mediaSources guard mirrors the enrichment trigger: an episode already carrying streams is fully detailed, so a missing overview is final.
                                ExpandableTextBoxPlaceholder()
                                    .padding(.horizontal, metrics.rowInset)
                            }

                            if !vm.seasons.isEmpty {
                                seasonSection(vm: vm)
                                    .id("episodeRow")
                            } else if vm.isLoadingSeasons {
                                // getSeasons in flight: skeleton tabs + episode row so it isn't a blank gap on a slow CDN. Swapped for the real section once seasons arrive.
                                seasonSectionSkeleton(vm: vm)
                                    .id("episodeRow")
                            }

                            // Cast ahead of the tech strip (Sodalite#47): with the season/episode
                            // block above it, the cast row sat far down the page for viewers who
                            // only want the people. Codec details follow one row later.
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

                            if displayItem.mediaStreams != nil || displayItem.mediaSources != nil {
                                TechInfoBox(item: displayItem)
                                    .animation(.easeInOut(duration: 0.3), value: selectedEpisode?.id)
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

                            // Same split the search screen teaches: what the server has on top, what it
                            // would have to fetch below, under the header the catalog already uses.
                            if !vm.catalogSimilar.isEmpty {
                                SeerrHorizontalMediaRow(
                                    title: "search.section.catalog",
                                    items: vm.catalogSimilar,
                                    onItemSelected: { navigateToSeerrRequest = $0 }
                                )
                            }
                        }
                        .onAppear {
                            episodeRowScrollProxy = outerProxy
                        }
                    }
                }
                .modifier(PageScrollProxyCapture(proxy: $pageScrollProxy))
                .transition(.opacity)
            } else {
                // Centred spinner; gating on isLoading avoids the field-fill repaint storm (play title + subtitle + progress all change in a 300ms window) and lands the user on one finished render.
                ZStack {
                    ProgressView()
                    // Invisible focus anchor, else Menu on the loading screen propagates past the nav stack and quits the app instead of popping back.
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
                    item: playItem,
                    startFromBeginning: playFromBeginning,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: userID),
                    cachedPlaybackInfo: viewModel?.cachedPlaybackInfo,
                    preferredMediaSourceID: pendingSourceID,
                    playQueue: playQueue,
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
        // task(id:), NOT onChange: onChange only sees transitions, and on a cold launch the play
        // target can already be resolved when this view first renders (the deep-link resolver
        // waits for the session and fetches ahead of it), leaving nothing to transition to.
        .task(id: autoPlayTargetKey) {
            maybeAutoPlay()
            maybePendingPlay()
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
                playItem = choice.item
                playFromBeginning = choice.fromBeginning
                playOriginatedFromPlayButton = choice.fromPlayButton
                pendingSourceID = source.id
                didPickVersion = true
                versionChoice = nil
            }
        }
        .onChange(of: showPlayer) { _, isPlaying in
            if !isPlaying {
                // Restore focus to the control the user used (Play button vs episode card). Two-step write (nil then target) forces a real transition (same-value write is a no-op); DispatchQueue.main.async batches the second write into the same render cycle so no intermediate no-focus flash.
                if playOriginatedFromPlayButton {
                    playButtonFocused = false
                    DispatchQueue.main.async {
                        playButtonFocused = true
                    }
                } else if let ep = playItem {
                    // Scroll back to the episode row first, else modal-dismiss restoration + the nil-flicker transition leave the outer ScrollView pinned at the top.
                    if let proxy = episodeRowScrollProxy {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("episodeRow", anchor: .top)
                        }
                    }
                    // The session may have walked several episodes past the card it was started
                    // from, and that card is the one the row is still parked on, so the target is
                    // off-row and unrendered. A focusedEpisodeID write for an unrendered card is a
                    // silent no-op, hence the same scroll-then-focus route the season bridge takes.
                    // The nil write first is the two-step that forces a real transition; its own
                    // effect on the aim is overwritten on the line below on purpose.
                    focusedEpisodeID = nil
                    episodeAim.sessionMoved(to: ep.id)
                    pendingEpisodeFocus = ep.id
                }
                playItem = nil
                playOriginatedFromPlayButton = false
            }
        }
        // AppRouter bumps this on every deep-link arrival so a TopShelf tap on a different item tears down the active player session and surfaces the new detail sheet cleanly.
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        // The session switched episodes behind the modal (auto-advance, queue, season picker). Follow
        // it, else leaving the player drops the user back on the episode they STARTED three episodes
        // ago. Foreign series (a shuffle queue crossing shows) are not ours to display.
        .onReceive(NotificationCenter.default.publisher(for: .playerDidSwitchItem)) { note in
            guard let episode = note.userInfo?[PlayerItemSwitchKey.item] as? JellyfinItem,
                  episode.seriesId == item.id else { return }
            playItem = episode
            selectedEpisode = episode
            // The row's memory still names the card the player was started from, ten auto-advances
            // ago. Move it along with the session, else every entry into the row (the return from
            // the player included) aims at the episode that was started rather than the one watched.
            episodeAim.sessionMoved(to: episode.id)
            // Rolled into the next season: its episode row has to be loaded or the focus restore on
            // dismiss has no card to land on.
            if let seasonID = episode.seasonId, viewModel?.selectedSeasonID != seasonID {
                Task { await viewModel?.loadEpisodes(seasonID: seasonID) }
            }
        }
        // The player continued on the item that replaced the one it was asked to play (a *arr upgrade
        // rewrote the file, so the library minted a new id). Swap the corpse out of the lists here, else
        // the next tap on that episode fails exactly the same way.
        .onReceive(NotificationCenter.default.publisher(for: .libraryItemDidReplace)) { note in
            guard let staleID = note.userInfo?[LibraryItemReplacementKey.staleID] as? String,
                  let replacement = note.userInfo?[LibraryItemReplacementKey.item] as? JellyfinItem,
                  replacement.seriesId == item.id else { return }
            viewModel?.applyItemReplacement(staleID: staleID, newItem: replacement)
            if playItem?.id == staleID { playItem = replacement }
            if selectedEpisode?.id == staleID { selectedEpisode = replacement }
        }
        // Posted once Jellyfin confirms the stop position. Patch resume position in place from the payload (race-free) across every in-memory holder including view-side selectedEpisode (issue #24). refreshResumePosition only reconciles played/next-up; the patch is re-applied after so a stale cached re-fetch can't regress the just-played position.
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { note in
            let itemID = note.userInfo?[PlaybackProgressKey.itemID] as? String
            let ticks = note.userInfo?[PlaybackProgressKey.positionTicks] as? Int64
            Task { @MainActor in
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                patchSelectedEpisodePosition(itemID: itemID, ticks: ticks)
                await viewModel?.refreshResumePosition()
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                patchSelectedEpisodePosition(itemID: itemID, ticks: ticks)
            }
        }
        .navigationDestination(item: $navigateToItem) { item in
            DetailRouterView(item: item)
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
        .navigationDestination(item: $navigateToSeerrRequest) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .onAppear {
            if viewModel == nil, let userID = appState.activeUser?.id {
                selectedEpisode = initialEpisode
                viewModel = DetailViewModel(
                    item: item,
                    itemService: dependencies.jellyfinItemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    libraryService: dependencies.jellyfinLibraryService,
                    playbackService: dependencies.jellyfinPlaybackService,
                    seerrMediaService: catalogSimilarService,
                    initialEpisode: initialEpisode
                )
                Task {
                    await viewModel?.loadFullDetail()
                    updateBackdropURL()
                }
                // Episode deep-link paints with isLoading already false, so the false-transition that normally seeds the backdrop + pushes focus never fires; do both here.
                if initialEpisode != nil {
                    updateBackdropURL()
                    deferOnMain(by: 0.1) {
                        playButtonFocused = true
                    }
                }
            }
            // Open the animation gate once the cover's present transition has settled.
            deferOnMain(by: 0.35) { didSettleIn = true }
        }
        .onChange(of: viewModel?.isLoading) { _, loading in
            updateBackdropURL()
            // Play button is out of the tree at first paint; push focus once isLoading flips false. Tiny defer rides out the focus-commit race.
            if loading == false {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        .onChange(of: selectedEpisode?.id) { _, newID in
            updateBackdropURL()
            // Episode lists are slim (no MediaStreams/MediaSources); on opening into episode mode pull full detail and swap in (same id) so the TechInfoBox can render codec/resolution.
            guard let newID, let vm = viewModel,
                  let episode = selectedEpisode, episode.id == newID,
                  episode.mediaStreams == nil, episode.mediaSources == nil else { return }
            Task {
                let enriched = await vm.enrichedEpisode(for: episode)
                if selectedEpisode?.id == enriched.id {
                    selectedEpisode = enriched
                }
                // Settled either way (enrichedEpisode returns the input on failure): release the synopsis placeholder so it can't sit empty forever.
                settledEpisodeDetailIDs.insert(episode.id)
            }
        }
        .sheet(isPresented: $isPresentingDeleteSheet) {
            if let vm = viewModel {
                let popDetail = dismiss
                MediaDeletionSheet(
                    mode: .series(
                        itemID: vm.item.id,
                        tmdbID: vm.item.tmdbID,
                        title: vm.item.name,
                        seasons: deletionSeasonOptions(from: vm.seasons)
                    ),
                    onConfirm: { request in
                        do {
                            if request.deleteEntireSeries {
                                try await dependencies.mediaDeletionService.deleteSeries(
                                    itemID: vm.item.id,
                                    tmdbID: vm.item.tmdbID,
                                    cascadeToArrStack: request.cascadeToArrStack
                                )
                            } else {
                                try await dependencies.mediaDeletionService.deleteSeasons(
                                    seasonItemIDs: request.seasonItemIDs,
                                    cascadeToArrStack: false
                                )
                            }
                            // Drop the on-disk filter cache so Library/Home rows don't keep showing deleted items until natural eviction. Every profile on this server, not just the active one: the file is gone for all of them.
                            if let serverID = appState.activeServer?.id {
                                FilterCache.shared.evict(serverID: serverID)
                            }
                            NotificationCenter.default.post(name: .homeItemDidDelete, object: nil)
                            // The cascade also cleared the title's open Seerr requests, so the request lists are stale.
                            if request.cascadeToArrStack {
                                NotificationCenter.default.post(name: .seerrRequestsDidChange, object: nil)
                            }
                            // Only pop the detail on whole-series delete; seasons-only leaves something worth viewing.
                            if request.deleteEntireSeries {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(1100))
                                    popDetail()
                                }
                            } else {
                                // Seasons-only: refresh so deleted season tabs drop out instead of lingering until reopen.
                                await vm.refreshSeasons()
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

    private func updateBackdropURL() {
        // Always the series backdrop (higher-res than the per-episode thumbnail, and dodges corrupt episode thumbnails). On an episode deep-link the series stub has no backdrop tags yet, so fall back to the episode's parent-series tags (same image) to paint on the first frame.
        guard let viewModel else {
            backdropURL = nil
            return
        }
        if let url = viewModel.backdropURL(for: viewModel.item) {
            backdropURL = url
        } else if let episode = selectedEpisode {
            // Sodalite#50: this fallback would otherwise take the episode's OWN backdrop first and
            // paint it full bleed. While veiled, go straight to the parent series art.
            backdropURL = SpoilerReveal.isHidden(episode, dependencies: dependencies, appState: appState, surface: .artwork)
                ? dependencies.jellyfinImageService.parentBackdropURL(for: episode)
                : viewModel.backdropURL(for: episode)
        } else {
            backdropURL = nil
        }
    }

    // MARK: - Glass Panel

    private func glassPanel(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Panel title is the episode name in episode mode; the series root has none (logo lives in the hero slot, see DetailContentOverlay).
            if isShowingEpisode {
                Text(selectedEpisode?.name ?? "")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .multilineTextAlignment(isPhonePortrait ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: isPhonePortrait ? .center : .leading)
            }

            // Metadata+tagline row one, genres+credits row two, baseline-aligned so columns sit level; series-level tagline/crew/studios in both modes so the episode panel matches the root.
            DetailInfoRows(
                item: vm.item,
                hasFullDetail: vm.hasFullDetail,
                hasLeftSecondary: !isShowingEpisode && !(vm.item.genres?.isEmpty ?? true),
                leftSecondaryPending: !isShowingEpisode && !vm.hasFullDetail && vm.item.genres == nil
            ) {
                if isShowingEpisode {
                    // Single metadata line (runtime + series genres). S/E pair left the panel (Sodalite#15 round 6) since the play-button subtitle already carries it; keeps the episode panel at title + one line.
                    if let line = episodeMetadataLine(vm: vm) {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    ItemMetadataRow(item: vm.item, showRuntime: false) {
                        if let count = vm.item.childCount, count > 0 {
                            AnyView(Text("detail.seasonCount \(count)"))
                        } else {
                            AnyView(EmptyView())
                        }
                    }
                }
            } leftSecondary: {
                // Series genres, one line only: a long list (e.g. One Piece's seven) wraps to two lines and makes the panel tall enough to land at a different scroll position.
                if !isShowingEpisode, let genres = vm.item.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Episode panel's single metadata line ("43 min · Genre · Genre"); episode runtime + series genres. nil when both absent so the line collapses.
    private func episodeMetadataLine(vm: DetailViewModel) -> String? {
        var parts: [String] = []
        if let runtime = selectedEpisode?.runTimeTicks {
            parts.append(runtime.ticksToDisplay)
        }
        parts.append(contentsOf: vm.item.genres ?? [])
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Action Buttons

    /// Button row below the glass panel, outside it (Sodalite#15 round 6) so the plate stays a compact metadata card; each GlassActionButton carries its own material so the row needs no plate.
    private func actionButtonRow(vm: DetailViewModel) -> some View {
        Group {
            if isPhonePortrait {
                VStack(spacing: 12) {
                    primaryActionButton(vm: vm)
                        .frame(maxWidth: .infinity)
                    // Centered, and wrapping to a second line rather than scrolling: a button-heavy
                    // series has more actions than one portrait line holds.
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
            title: playTitle(vm: vm),
            systemImage: "play.fill",
            isProminent: true,
            subtitle: playButtonSubtitle(vm: vm),
            progressFraction: playProgressFraction(vm: vm),
            // Spinner until a concrete play target: avoids the "Abspielen" → "Fortsetzen + S1, E5 · 12:34" repaint when getNextUp lands a few hundred ms after appear.
            isLoading: playTarget(vm: vm) == nil,
            // Never disabled: a series whose getNextUp outruns the 500ms snapshot deadline paints its
            // action row with Play disabled, and the row's auto-focus then lands on Shuffle while the
            // playButtonFocused push is dropped on the disabled button (Vincent, 2026-08-17).
            disablesWhileLoading: false,
            action: {
                let ep = playTarget(vm: vm)
                if let ep {
                    requestPlay(ep, fromBeginning: false, fromPlayButton: true)
                } else {
                    // Pressed while the target is still resolving: remember the intent instead of
                    // eating the press, the target-keyed task below launches it when it lands.
                    pendingPlayRequest = true
                }
            }
        )
        .focused($playButtonFocused)
    }

    // MARK: - Spoiler rule (Sodalite#50 follow-up)

    private func spoilerRuleTitle(_ rule: SpoilerSeriesRule) -> LocalizedStringKey {
        switch rule {
        case .hidden: "detail.spoiler.rule.hidden"
        case .shown: "detail.spoiler.rule.shown"
        case .standard: "detail.spoiler.rule.standard"
        }
    }

    private func spoilerRuleSymbol(_ rule: SpoilerSeriesRule) -> String {
        switch rule {
        case .hidden: "eye.slash"
        case .shown: "eye"
        case .standard: "gearshape"
        }
    }

    @ViewBuilder
    private func spoilerRuleMenu(seriesID: String) -> some View {
        let key = SpoilerPolicy.seriesKey(userID: appState.activeUser?.id ?? "", seriesID: seriesID)
        let current = dependencies.spoilerSeriesRules.rule(for: key)
        ForEach(SpoilerSeriesRule.allCases, id: \.self) { rule in
            Button {
                setSpoilerRule(rule, seriesID: seriesID)
            } label: {
                // Checkmark on the active rule, its own symbol otherwise: the menu has to show
                // where the show stands, not just what can be picked.
                Label(spoilerRuleTitle(rule), systemImage: rule == current ? "checkmark" : spoilerRuleSymbol(rule))
            }
        }
    }

    private func setSpoilerRule(_ rule: SpoilerSeriesRule, seriesID: String) {
        guard let userID = appState.activeUser?.id else { return }
        dependencies.spoilerSeriesRules.set(
            rule,
            for: SpoilerPolicy.seriesKey(userID: userID, seriesID: seriesID)
        )
    }

    @ViewBuilder
    private func secondaryActionButtons(vm: DetailViewModel) -> some View {
            // Shuffle whole series (server SortBy=Random scoped by series id). Hidden in the episode panel.
            if !isShowingEpisode {
                GlassActionButton(
                    title: "action.shuffle",
                    systemImage: "shuffle",
                    // Spinner on tap (VideoShuffleQueue.build lands a few hundred ms later), else the row sits inert until showPlayer flips.
                    isLoading: isShuffleLoading,
                    action: {
                        guard let userID = appState.activeUser?.id else { return }
                        let seriesID = vm.item.id
                        isShuffleLoading = true
                        Task {
                            let queue = await VideoShuffleQueue.build(
                                parentID: seriesID,
                                itemTypes: [.episode],
                                service: dependencies.jellyfinLibraryService,
                                userID: userID
                            )
                            isShuffleLoading = false
                            guard let first = queue.first else { return }
                            playItem = first
                            playQueue = queue
                            playFromBeginning = true
                            playOriginatedFromPlayButton = true
                            pendingSourceID = nil
                            showPlayer = true
                        }
                    }
                )
            }

            // Restart-from-beginning when the play target carries progress (button reads "Resume"), mirroring MovieDetailView. playTarget covers both series root and episode panel.
            if let target = playTarget(vm: vm),
               let ticks = target.userData?.playbackPositionTicks,
               ticks > 0 {
                GlassActionButton(
                    title: "detail.replay",
                    systemImage: "arrow.counterclockwise",
                    action: {
                        requestPlay(target, fromBeginning: true, fromPlayButton: true)
                    }
                )
            }

            if !isShowingEpisode && vm.hasLocalTrailer {
                GlassActionButton(
                    title: "detail.trailer",
                    systemImage: "play.rectangle",
                    action: {
                        Task {
                            if let trailer = await vm.loadTrailer() {
                                playItem = trailer
                                playFromBeginning = true
                                playOriginatedFromPlayButton = false
                                showPlayer = true
                            }
                        }
                    }
                )
            }

            if !isShowingEpisode {
                GlassActionButton(
                    title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                    action: { Task { await vm.toggleFavorite() } }
                )
            }

            if !isShowingEpisode {
                GlassActionButton(
                    title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                    systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                    action: { Task { await vm.togglePlayed() } }
                )
            }

            // Shows the EFFECTIVE state for this series, so a tap always reads as "do the other
            // thing"; the three explicit states live in the context menu.
            if !isShowingEpisode {
                let seriesID = vm.item.id
                let hidesNow = dependencies
                    .spoilerPolicy(userID: appState.activeUser?.id)
                    .effectiveHidesSeries(seriesID)
                GlassActionButton(
                    title: hidesNow ? "detail.spoiler.show" : "detail.spoiler.hide",
                    systemImage: hidesNow ? "eye" : "eye.slash",
                    action: { setSpoilerRule(hidesNow ? .shown : .hidden, seriesID: seriesID) }
                )
                .contextMenu { spoilerRuleMenu(seriesID: seriesID) }
            }

            if isShowingEpisode {
                GlassActionButton(
                    title: "detail.showSeries",
                    systemImage: "xmark",
                    action: {
                        withAnimation { selectedEpisode = nil }
                    }
                )
            }

            // Deliberately selectedEpisode, not playTarget: playTarget also resolves to an episode
            // while the panel is closed, so the series button would silently favorite an episode.
            if isShowingEpisode, let ep = selectedEpisode {
                GlassActionButton(
                    title: vm.isFavorite(ep) ? "detail.unfavorite" : "detail.favorite",
                    systemImage: vm.isFavorite(ep) ? "heart.fill" : "heart",
                    action: {
                        let target = !vm.isFavorite(ep)
                        Task { await vm.setEpisodeFavorite(ep, isFavorite: target) }
                    }
                )
            }

            if isShowingEpisode, let ep = selectedEpisode {
                GlassActionButton(
                    title: vm.isPlayed(ep) ? "detail.markUnwatched" : "detail.markWatched",
                    systemImage: vm.isPlayed(ep) ? "checkmark.circle.fill" : "checkmark.circle",
                    action: {
                        let target = !vm.isPlayed(ep)
                        Task { await vm.setEpisodePlayed(ep, isPlayed: target) }
                    }
                )
            }

            if !isShowingEpisode,
               appState.isSeerrConnected,
               let tmdbID = vm.item.tmdbID,
               shouldShowSeerrRequest(for: vm.item) {
                GlassActionButton(
                    title: "detail.requestInSeerr",
                    systemImage: "tray.and.arrow.down",
                    action: {
                        navigateToSeerrRequest = .stub(tmdbID: tmdbID, mediaType: .tv)
                    }
                )
            }

            // Delete last, matching MovieDetailView, so the destructive action sits furthest from Play.
            if canDelete && !isShowingEpisode {
                GlassActionButton(
                    title: "detail.delete.button",
                    systemImage: "trash",
                    isDestructive: true,
                    action: { isPresentingDeleteSheet = true }
                )
            }
    }

    /// Patch the open episode panel's resume position when the played item is selectedEpisode (issue #24). selectedEpisode lives on the view not the VM, and playTarget prioritises it, so applyPlaybackPosition can't reach it. No-op unless the id matches.
    private func patchSelectedEpisodePosition(itemID: String?, ticks: Int64?) {
        guard let itemID, let ticks,
              selectedEpisode?.id == itemID else { return }
        selectedEpisode?.setResumePosition(ticks)
    }

    /// Single source of truth for which episode the play button acts on (playTitle/subtitle/progress + action all read this). Order: tapped selectedEpisode, currentEpisodeID match, getNextUp (lands before the full list), first loaded episode.
    private func playTarget(vm: DetailViewModel) -> JellyfinItem? {
        if let selectedEpisode { return selectedEpisode }
        if let id = vm.currentEpisodeID,
           let match = vm.episodes.first(where: { $0.id == id }) {
            return match
        }
        if let next = vm.nextUpEpisode { return next }
        return vm.episodes.first
    }

    private func playTitle(vm: DetailViewModel) -> LocalizedStringKey {
        if let ticks = playTarget(vm: vm)?.userData?.playbackPositionTicks,
           ticks > 0 {
            return "detail.resume"
        }
        return "detail.play"
    }

    /// Play-button subtitle: "S1, E5 · 12:34" when resuming, "S1, E5" fresh, nil if no resolvable target.
    private func playButtonSubtitle(vm: DetailViewModel) -> String? {
        guard let target = playTarget(vm: vm) else { return nil }

        var parts: [String] = []
        let episodeLabel = episodeShorthand(for: target)
        if !episodeLabel.isEmpty {
            parts.append(episodeLabel)
        }
        if let ticks = target.userData?.playbackPositionTicks,
           ticks > 0,
           let stamp = ResumeTimeFormatter.format(ticks: ticks) {
            parts.append(stamp)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 0…1 progress into the target episode; nil when fresh or no run-time metadata so the button suppresses the overlay instead of drawing an empty bar.
    private func playProgressFraction(vm: DetailViewModel) -> Double? {
        guard let target = playTarget(vm: vm),
              let ticks = target.userData?.playbackPositionTicks, ticks > 0,
              let total = target.runTimeTicks, total > 0 else {
            return nil
        }
        return min(1.0, max(0.0, Double(ticks) / Double(total)))
    }

    private func episodeShorthand(for episode: JellyfinItem) -> String {
        EpisodeMetadataFormatter.seasonEpisode(season: episode.parentIndexNumber,
                                               episode: episode.indexNumber)
    }

    /// "Request in Seerr" only for series that may still grow (status "Continuing" vs "Ended"). Missing status stays permissive and shows the button.
    private func shouldShowSeerrRequest(for item: JellyfinItem) -> Bool {
        guard let status = item.status else { return true }
        return status == "Continuing"
    }

    /// Resolve a cast member to a TMDB person id and open the person page; inert when the server has no TMDB id.
    private func handlePersonTap(_ member: CastMember) {
        navigateToPerson = PersonRoute(member: member)
    }

    // MARK: - Season Section

    /// The selected season's synopsis, when the library has one. The box and the focus routing read the same accessor, so an up-move can never be aimed at a box that is not on screen.
    private func seasonOverview(vm: DetailViewModel) -> String? {
        guard let overview = vm.selectedSeason?.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty else { return nil }
        return overview
    }

    /// Where a move down into the episode row lands. Every entry path (the focus bridge, the one-shot redirect below it, the return from the player) reads this one resolver so they cannot aim at different cards.
    private func episodeEntryTarget(vm: DetailViewModel) -> String? {
        episodeAim.target(in: vm.episodes.map(\.id), currentEpisodeID: vm.currentEpisodeID)
    }

    /// Up out of the episode row. It used to go straight to the season bar, which skipped the season synopsis sitting between the two (reachable downwards, unreachable upwards). Now the synopsis takes the first stop when there is one, and its own up-move carries on to the season bar.
    private func focusUpFromEpisodeRow(vm: DetailViewModel) {
        if seasonOverview(vm: vm) != nil {
            pendingSeasonOverviewFocus = true
        } else {
            // Deferred for the bridge's sake: a @FocusState write on the tick that just committed the bridge's own focus is swallowed.
            let target = vm.selectedSeasonID
            deferOnMain(by: 0.03) { focusedSeasonID = target }
        }
    }

    private func seasonSection(vm: DetailViewModel) -> some View {
        // .focusSection (at the bottom) keeps up/down inside the season+episode block, else a far-right episode's up-swipe bypasses the season bar and lands on the overview textbox; the onMoveCommand redirect then snaps to the selected tab.
        VStack(alignment: .leading, spacing: 20) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(vm.seasons) { season in
                            SeasonTab(
                                id: season.id,
                                name: season.name,
                                isSelected: vm.selectedSeasonID == season.id,
                                focusedID: $focusedSeasonID,
                                action: {
                                    // Don't reset the hero to series root here: flipping the short episode panel to the taller series panel while focus is on the season bar makes tvOS follow the tab and scroll the page down. "Serie anzeigen" resets the hero explicitly.
                                    Task { await vm.loadEpisodes(seasonID: season.id) }
                                }
                            )
                            .id(season.id)
                            .contextMenu {
                                Button {
                                    let target = !vm.isPlayed(season)
                                    Task { await vm.setSeasonPlayed(seasonID: season.id, isPlayed: target) }
                                } label: {
                                    Label(
                                        vm.isPlayed(season) ? "detail.season.markUnwatched" : "detail.season.markWatched",
                                        systemImage: vm.isPlayed(season) ? "checkmark.circle.fill" : "checkmark.circle"
                                    )
                                }
                                Divider()
                                // Reachable from the lower half of the page too. These set the
                                // SERIES rule, which is what their titles say.
                                spoilerRuleMenu(seriesID: vm.item.id)
                            }
                        }
                    }
                    // Focus scale 1.05 needs vertical slack or the halo clips against the scroll-view edges.
                    .padding(.horizontal, metrics.rowInset)
                    .padding(.vertical, 12)
                }
                .onChange(of: focusedSeasonID) { oldID, newID in
                    // Force focus back to the current season on entry from above (oldID nil), return from the episode row (episodesHadFocus), or fall-through.
                    let cameFromOutside = oldID == nil || episodesHadFocus
                    if cameFromOutside, let newID, newID != vm.selectedSeasonID {
                        let target = vm.selectedSeasonID
                        // Defer one runloop tick: a synchronous @FocusState write inside its own onChange is dropped on tvOS; DispatchQueue.main is honored, Task/Task.sleep hops are swallowed.
                        DispatchQueue.main.async {
                            focusedSeasonID = target
                        }
                    }
                    episodesHadFocus = false
                    if newID != nil {
                        lastFocusedArea = .season
                    }
                    if let focusedID = focusedSeasonID {
                        withAnimation { proxy.scrollTo(focusedID, anchor: .center) }
                    }
                    if newID != nil {
                        episodeRedirectDone = false
                    }
                }
                .onChange(of: focusedEpisodeID) { oldEpisode, newEpisode in
                    if newEpisode != nil {
                        episodesHadFocus = true
                        lastFocusedArea = .episode
                    } else if let oldEpisode {
                        episodeAim.focusLeft(oldEpisode)
                    }
                }
                .onChange(of: vm.selectedSeasonID) { _, newID in
                    episodeRedirectDone = false
                    withAnimation { proxy.scrollTo(newID, anchor: .center) }
                }
            }

            // Season synopsis, same box as the series overview. Jellyfin fills Season.Overview from the
            // metadata provider, so it renders only where the library actually has one. Placed below the
            // bar (it describes the season the tabs just selected) and above the focus bridge, so an
            // up-swipe out of the episode row still hits the bridge first and its redirect is unchanged.
            if let season = vm.selectedSeason, let seasonOverview = seasonOverview(vm: vm) {
                ExpandableTextBox(
                    text: seasonOverview,
                    spoilerItem: season,
                    // Carry on to the selected tab rather than whatever the geographic picker finds above.
                    onFocusMovedUp: {
                        let target = vm.selectedSeasonID
                        deferOnMain(by: 0.03) { focusedSeasonID = target }
                    },
                    // Reading the synopsis counts as coming from above, so the next down-move crosses the bridge into the episode row instead of being bounced back up here.
                    onFocusChanged: { focused in
                        if focused { lastFocusedArea = .season }
                    },
                    focusRequest: $pendingSeasonOverviewFocus
                )
                .padding(.horizontal, metrics.rowInset)
            }

            // Full-width invisible focus bridge between the season bar and episode row: an up-swipe from a far-right episode lands here before tvOS's picker continues up into the overview/tech-info cards, then redirects by which row the user came from on the next cycle.
            // Height 24pt: tvOS's geographic picker weights frame size on proximity ties and skips sub-10pt focusables near larger ones (1pt missed often, 8pt flaky on fast season-tab→down). 24pt is reliable.
            // tvOS only: touch has no focus picker to redirect, so on iOS the bridge is 24pt of dead
            // space plus two 20pt VStack gaps between the season block and the episode row.
            #if os(tvOS)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .focusable()
                .focused($focusBridgeActive)
                .onChange(of: focusBridgeActive) { _, active in
                    guard active else { return }
                    // FocusState writes need a defer past the tick committing the bridge's own focus or tvOS swallows them (season case). The episode case writes plain @State (pendingEpisodeFocus), not subject to the race, so it fires immediately (shaves the 30ms "fast press needs two clicks" latency).
                    let deferFocusWrite = { (work: @escaping @MainActor () -> Void) in
                        deferOnMain(by: 0.03, work)
                    }
                    switch lastFocusedArea {
                    case .episode:
                        focusUpFromEpisodeRow(vm: vm)
                    case .season:
                        if let target = episodeEntryTarget(vm: vm) {
                            // pendingEpisodeFocus is plain @State; the episode-row ScrollViewReader scrolls it into the LazyHStack then writes focusedEpisodeID.
                            pendingEpisodeFocus = target
                        }
                    case .none:
                        // First focus into this section (e.g. NavigationStack push): default to the selected season.
                        let target = vm.selectedSeasonID
                        deferFocusWrite { focusedSeasonID = target }
                    }
                }
            #endif

            if vm.episodes.isEmpty && vm.isLoadingEpisodes {
                episodeSkeletonRow(vm: vm)
            } else if !vm.episodes.isEmpty {
                ScrollViewReader { episodeProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: hSizeClass == .compact ? metrics.itemSpacing : 24) {
                            ForEach(vm.episodes) { episode in
                                VStack(alignment: .leading, spacing: 10) {
                                    Button {
                                        requestPlay(episode, fromBeginning: false, fromPlayButton: false)
                                    } label: {
                                        EpisodeLandscapeCard(
                                            episode: episode,
                                            imageURL: dependencies.jellyfinImageService.episodeThumbnailURL(for: episode),
                                            isSelected: selectedEpisode?.id == episode.id,
                                            isCurrent: vm.currentEpisodeID == episode.id,
                                            isFocused: focusedEpisodeID == episode.id,
                                            isPlayed: vm.isPlayed(episode),
                                            isFavorite: vm.isFavorite(episode)
                                        )
                                    }
                                    .buttonStyle(EpisodeCardButtonStyle())
                                    .focused($focusedEpisodeID, equals: episode.id)
                                    // Prime the season-bar target before the up-move resolves, else tvOS's geographic picker skips the bar (far-right episode outside the tabs' span) and lands on the overview above.
                                    #if os(tvOS)
                                    .onMoveCommand { direction in
                                        if direction == .up {
                                            focusUpFromEpisodeRow(vm: vm)
                                        }
                                    }
                                    #endif
                                    .contextMenu {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                selectedEpisode = episode
                                            }
                                            #if os(tvOS)
                                            // Context menu restores focus to this card on dismiss; flag it so the focusedEpisodeID observer bounces focus up to Play (a fixed delay lost the race against the restore). The delayed write is a fallback when focus never visibly cycles.
                                            pendingPlayFocusAfterMenu = true
                                            deferOnMain(by: 0.6) {
                                                guard pendingPlayFocusAfterMenu else { return }
                                                pendingPlayFocusAfterMenu = false
                                                playButtonFocused = false
                                                DispatchQueue.main.async { playButtonFocused = true }
                                            }
                                            #else
                                            // Touch has no focus engine, so the focus bounce above (the only thing that
                                            // scrolls the episode panel into view on tvOS) is inert here: the state flipped
                                            // correctly but the panel sits a viewport up and the tech info far below, so the
                                            // action read as a no-op. Scroll there explicitly instead. The defer rides out
                                            // the context menu's dismiss morph, which otherwise fights the scroll.
                                            scrollToEpisodePanel()
                                            #endif
                                        } label: {
                                            Label("detail.episode.showDetails", systemImage: "info.circle")
                                        }

                                        Button {
                                            requestPlay(episode, fromBeginning: true, fromPlayButton: false)
                                        } label: {
                                            Label("detail.play", systemImage: "play.fill")
                                        }

                                        if let ticks = episode.userData?.playbackPositionTicks, ticks > 0 {
                                            Button {
                                                requestPlay(episode, fromBeginning: false, fromPlayButton: false)
                                            } label: {
                                                Label("detail.resume", systemImage: "play.circle")
                                            }
                                        }

                                        Button {
                                            let target = !vm.isPlayed(episode)
                                            Task { await vm.setEpisodePlayed(episode, isPlayed: target) }
                                        } label: {
                                            Label(
                                                vm.isPlayed(episode) ? "detail.markUnwatched" : "detail.markWatched",
                                                systemImage: vm.isPlayed(episode) ? "checkmark.circle.fill" : "checkmark.circle"
                                            )
                                        }

                                        Button {
                                            let target = !vm.isFavorite(episode)
                                            Task { await vm.setEpisodeFavorite(episode, isFavorite: target) }
                                        } label: {
                                            Label(
                                                vm.isFavorite(episode) ? "detail.unfavorite" : "detail.favorite",
                                                systemImage: vm.isFavorite(episode) ? "heart.fill" : "heart"
                                            )
                                        }

                                        // Sodalite#50. For an episode without a synopsis the box is
                                        // not focusable, so this is the only way to uncover its still.
                                        if SpoilerReveal.isHidden(episode, dependencies: dependencies, appState: appState) {
                                            Button {
                                                SpoilerReveal.reveal(episode, dependencies: dependencies, appState: appState)
                                            } label: {
                                                Label("spoiler.reveal", systemImage: "eye")
                                            }
                                        }
                                    }

                                    // Per-card synopsis box; reserves a fixed three-line height even when empty so every column stays the same height.
                                    EpisodeSynopsisBox(
                                        episode: episode,
                                        text: episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    )
                                }
                                .id(episode.id)
                            }
                        }
                        .padding(.horizontal, metrics.rowInset)
                        .padding(.vertical, 16)
                    }
                    .scrollPosition($episodeRowPosition)
                    .onChange(of: vm.selectedSeasonID) { _, _ in
                        // Back to the row's own start, NOT scrollTo(first, anchor: .leading): that parks the
                        // first card's leading edge on the viewport edge, which eats the row inset and leaves
                        // the card flush against the screen edge (Vincent, 2026-08-17). The inset is padding
                        // on the LazyHStack, so only an edge scroll keeps it.
                        episodeRowPosition.scrollTo(edge: .leading)
                        deferOnMain(by: 0.15) {
                            scrollToCurrentEpisode(proxy: episodeProxy, vm: vm)
                        }
                    }
                    .onChange(of: focusedEpisodeID) { _, newID in
                        // "Show Details" was picked and focus restored to the row: bounce up to Play. Two-step write forces a real transition (same-value write is a no-op).
                        if pendingPlayFocusAfterMenu, newID != nil {
                            pendingPlayFocusAfterMenu = false
                            playButtonFocused = false
                            DispatchQueue.main.async { playButtonFocused = true }
                            return
                        }
                        if newID != nil && !episodeRedirectDone {
                            episodeRedirectDone = true
                            if let target = episodeEntryTarget(vm: vm), newID != target {
                                focusedEpisodeID = target
                            }
                        }
                    }
                    .onChange(of: pendingEpisodeFocus) { _, target in
                        guard let target else { return }
                        // Scroll the target into the LazyHStack so its .focused modifier exists when we write focusedEpisodeID, else the write silently fails for an unrendered card (right-side 2-press case).
                        withAnimation(.easeInOut(duration: 0.2)) {
                            episodeProxy.scrollTo(target, anchor: .center)
                        }
                        deferOnMain {
                            focusedEpisodeID = target
                            pendingEpisodeFocus = nil
                        }
                    }
                    .onAppear {
                        scrollToCurrentEpisode(proxy: episodeProxy, vm: vm)
                    }
                }
            }
        }
        .focusSectionCompat()
    }

    @ViewBuilder
    /// Whole-section placeholder while getSeasons is in flight: skeleton season tabs above the episode skeleton row. Mirrors seasonSection's ScrollView/spacing/padding so the swap doesn't shift layout.
    private func seasonSectionSkeleton(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Same horizontal ScrollView as the real season bar, and not just for the swap: six
            // fixed 110pt tabs measure 742pt with the insets, so a bare HStack reports that width
            // to the page even when the viewport proposes 402. The content column then takes 742,
            // and every sibling (glass panel, action row, hero logo) is drawn at that width and
            // clipped on both edges until the seasons land, roughly a second later. The action row
            // stops wrapping too, since it suddenly has 710pt to fill.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.Theme.surface)
                            .frame(width: 110, height: 52)
                    }
                }
                .padding(.horizontal, metrics.rowInset)
                .padding(.vertical, 12)
            }

            episodeSkeletonRow(vm: vm)
        }
        .allowsHitTesting(false)
    }

    /// Shimmer row at the real 360x202 card footprint so the layout doesn't jump on episode-land. Card count from the season's childCount, clamped to a sane span.
    private func episodeSkeletonRow(vm: DetailViewModel) -> some View {
        let seasonCount = vm.seasons.first(where: { $0.id == vm.selectedSeasonID })?.childCount
        let count = min(max(seasonCount ?? 6, 3), 10)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: hSizeClass == .compact ? metrics.itemSpacing : 24) {
                ForEach(0..<count, id: \.self) { _ in
                    EpisodeSkeletonCard()
                }
            }
            .padding(.horizontal, metrics.rowInset)
            .padding(.vertical, 16)
        }
        .allowsHitTesting(false)
    }

    /// Brings the glass panel (now in episode mode) into view. Inert on tvOS, where pageScrollProxy stays nil and the focus engine does the scrolling.
    private func scrollToEpisodePanel() {
        deferOnMain(by: 0.35) {
            withAnimation(.easeInOut(duration: 0.4)) {
                pageScrollProxy?.scrollTo(Self.pageTopAnchor, anchor: .top)
            }
        }
    }

    private func scrollToCurrentEpisode(proxy: ScrollViewProxy, vm: DetailViewModel) {
        guard let currentID = vm.currentEpisodeID,
              vm.episodes.contains(where: { $0.id == currentID }) else { return }
        deferOnMain(by: 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}
