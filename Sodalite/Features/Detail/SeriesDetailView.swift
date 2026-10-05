import SwiftUI

struct SeriesDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.serverSession) private var serverSessionOverride
    /// The item's own server in a combined Home, the active one otherwise (Sodalite#85).
    private var session: ServerSession { serverSessionOverride ?? dependencies.sessionRegistry.active }
    private var sessionUserID: String? { session.isActive ? appState.activeUser?.id : session.userID }
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
    /// Sodalite#81: the episode or season whose download rung is being asked for.
    @State private var downloadTarget: DownloadTarget?
    /// Sodalite#81: one launch that streams a downloaded episode instead of playing the file.
    @State private var streamFromServer = false
    @State private var versionChoice: VersionPickerChoice?
    /// Which version the play target runs; keyed to that target, so tapping the next episode drops it (Sodalite#139).
    @State private var versionSelection = VersionSelection()
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
    /// Which control in the action row holds focus, nil while focus is anywhere else on the page.
    /// The secondaries leave the focus engine for that time, so an up-move out of the content can
    /// only land on Play (Sodalite#53, and #146 once the overview box that used to answer this went
    /// away). See `DetailAction`.
    @FocusState private var focusedAction: DetailAction?
    @State private var isPresentingDeleteSheet: Bool = false
    @State private var isPresentingMoreDetails = false
    /// Sodalite#146 round 3: Watched on a SERIES is the one control on the page that cannot be
    /// undone by pressing it again. The server cascades the mark to every episode and drops the
    /// show out of Resume, and pressing it a second time marks the whole show UNWATCHED rather than
    /// restoring what it replaced, so a mis-press costs per-episode progress a viewer may be three
    /// seasons into. Single episodes stay a plain toggle; they act on one asset and reverse cleanly.
    @State private var isConfirmingPlayedChange = false
    /// Set on episode "Show Details": the context menu restores focus to its anchor card on dismiss, so the focusedEpisodeID observer bounces focus up to the play button.
    @State private var pendingPlayFocusAfterMenu = false

    /// Seerr service for the catalog similar row, nil while the Catalog tab is hidden: switching it off is a parental measure (Sodalite#62), so the catalog has to be gone here as well, exactly as in Search and on person pages.
    private var catalogSimilarService: SeerrMediaServiceProtocol? {
        dependencies.appearancePreferences.isTabHidden(.catalog) ? nil : dependencies.seerrMediaService
    }

    /// See `MovieDetailView.canDelete(_:)`: the item's own `CanDelete` decides wherever the server
    /// sent it, the user policy is the fallback for a response without it (Sodalite#146).
    private func canDelete(_ item: JellyfinItem) -> Bool {
        guard session.allowsDeleteAndDownload else { return false }
        if let serverAnswer = item.canDelete { return serverAnswer }
        return appState.activeUser?.canDeleteContent == true
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

    /// Whether Menu has a series state to go back to, or has to leave the page. See the type.
    @State private var episodeOrigin = EpisodeStateOrigin()
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
    /// The episode the player session is on while it sits in front of the page. The row scrolls to it behind the modal, so the card the return restore aims at is already rendered when the player closes.
    @State private var episodeRowFollowID: String?
    /// Which cast card holds focus, for the row's entry aim (Sodalite#146 round 2). Same rule as the
    /// movie page: the first entry lands on the first card, after that the row remembers.
    @FocusState private var focusedCastID: String?
    @State private var castEntryAimed = false
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

    /// `fromPlayButton` preserves the focus-restoration origin flag the trigger sites set. Play starts
    /// the version the page shows; the picker is the version button's job now (Sodalite#139).
    private func requestPlay(_ episode: JellyfinItem, fromBeginning: Bool, fromPlayButton: Bool) {
        // Ordinary play is never a shuffle queue; drop any queue a prior
        // shuffle launch left behind so the launcher reuses single-item play.
        playQueue = []
        playItem = episode
        playFromBeginning = fromBeginning
        playOriginatedFromPlayButton = fromPlayButton
        showPlayer = true
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

    /// Whether a synopsis can still arrive for whatever the page is showing. The hero teaser and the
    /// box below the fold reserve their space on exactly this value, so the two cannot drift apart
    /// and reserve for different states.
    private var overviewMayStillLand: Bool {
        guard let vm = viewModel else { return true }
        guard isShowingEpisode else { return !vm.hasFullDetail }
        guard let episode = selectedEpisode else { return false }
        // Mirrors the enrichment trigger: an episode already carrying streams is fully detailed, so
        // a missing overview is final (Sodalite#15).
        return episode.awaitsMediaDetail
            && !settledEpisodeDetailIDs.contains(episode.id)
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
                contentOverlay(vm: vm)
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
        // Menu returns to the series state rather than dismissing the page (Sodalite#146). The page
        // swaps its header for an episode rather than pushing a screen, so tvOS had nothing to pop
        // and Menu went straight past it to the detail cover: opening an episode cost the whole show
        // page to get back out of.
        //
        // Only when a series state is actually BEHIND this one. An episode opened from Continue
        // Watching arrives with the page already in the episode state, and intercepting there put a
        // series page the viewer never asked for between them and Home, which is one press more than
        // before (Vincent, device, 2026-09-14).
        //
        // Via the nil-passing helper, because an empty closure would swallow the press that has to
        // reach the cover or the navigation stack behind it (Sodalite#140).
        .onExitCommandIfEnabled(isShowingEpisode && episodeOrigin.hasSeriesStateBehind, perform: closeEpisodeState)
        // iPhone portrait respects the safe area so detail content is not clipped under the status
        // bar; the backdrop keeps its own .ignoresSafeArea() to stay full-bleed. tvOS/iPad full-bleed.
        .ignoresSafeArea(when: !isPhonePortrait)
        .hidesToolbarBackground()
        .downloadRungDialog(target: $downloadTarget)
        .onChange(of: showPlayer) { _, isShowing in
            if !isShowing { streamFromServer = false }
        }
        .overlay {
            if let userID = sessionUserID {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: playItem,
                    startFromBeginning: playFromBeginning,
                    playbackService: session.playbackService,
                    itemService: session.itemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: appState.activeUser?.id),
                    cachedPlaybackInfo: viewModel?.cachedPlaybackInfo,
                    preferredMediaSourceID: versionSelection.preferredSourceID(for: playItem),
                    playQueue: playQueue,
                    localDownload: streamFromServer ? nil : playItem.flatMap { dependencies.downloadStore.completedItem($0.id) },
                    downloadStore: dependencies.downloadStore
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
        // AE#579, see hdr10PlusProbeKey: asked for the episode on screen, once per version.
        .task(id: hdr10PlusProbeKey) {
            guard isShowingEpisode else { return }
            let episode = displayItem
            await dependencies.hdr10PlusProbeStore.probeIfNeeded(
                item: episode,
                sourceID: versionSelection.preferredSourceID(for: episode))
        }
        .menuPresentation(item: $versionChoice) { choice in
            VersionPickerSheet(
                sources: choice.sources,
                tintColor: dependencies.appearancePreferences.effectiveTint(
                    isSupporter: dependencies.storeKitService.isSupporter
                ),
                selectedID: choice.selectedID
            ) { source in
                versionSelection.choose(source, for: choice.item)
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
                    let target = ep.id
                    deferOnMain(by: 0.6) {
                        LogTap.shared.note("[EpisodeRow] player_return target=\(target) focused=\(focusedEpisodeID ?? "nil")")
                    }
                }
                episodeRowFollowID = nil
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
            episodeOrigin.playerAdvanced(fromSeriesState: selectedEpisode == nil)
            selectedEpisode = episode
            // The row's memory still names the card the player was started from, ten auto-advances
            // ago. Move it along with the session, else every entry into the row (the return from
            // the player included) aims at the episode that was started rather than the one watched.
            episodeAim.sessionMoved(to: episode.id)
            // Moving the aim is not enough on its own: the row stays parked on the card the session
            // was started from, the new card sits off-row and unrendered, and the restore's scroll is
            // still in flight when its focus write lands, so a binge of more than a few episodes came
            // back on the start card. Scroll the row along now, while nobody is looking at it.
            episodeRowFollowID = episode.id
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
                personName: route.name,
                sourceTMDBID: route.sourceTMDBID
            )
                .detailCoverPush()
        }
        .navigationDestination(item: $navigateToSeerrRequest) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .onAppear {
            if viewModel == nil, let userID = sessionUserID {
                selectedEpisode = initialEpisode
                viewModel = DetailViewModel(
                    item: item,
                    itemService: session.itemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    libraryService: session.libraryService,
                    playbackService: session.playbackService,
                    seerrMediaService: catalogSimilarService,
                    initialEpisode: initialEpisode,
                    streamingQuality: { [dependencies] in dependencies.playbackPreferences.defaultStreamingQuality() }
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
        .onChange(of: viewModel?.isLoading) { _, _ in
            updateBackdropURL()
        }
        // Play is where a detail page opens, and HOW it gets there is the whole question
        // (Sodalite#146 round 2). It used to be a deferred `@FocusState` write once `isLoading`
        // flipped, which is a focus MOVE, and a move is what makes tvOS scroll the newly focused
        // control into its preferred place: about 180 pt above the bottom edge, against the 64 pt the
        // page reserves, which is the 116 pt the page was found resting at. `defaultFocus` is the
        // same destination without the move: it names where focus BELONGS when this subtree is first
        // evaluated, so there is no arrival to scroll to.
        //
        // It also explains why the defect came and went. A push racing the first focus evaluation is
        // either redundant or a move, depending on which lands first, and that is decided by how fast
        // the detail fetch returns.
        .defaultFocus($playButtonFocused, true)
        .onChange(of: selectedEpisode?.id) { _, newID in
            updateBackdropURL()
            // Episode lists are slim (no MediaStreams/MediaSources, or placeholder sources on a lazy server); on opening into episode mode pull full detail and swap in (same id) so the TechInfoBox and the version button see the real files.
            guard let newID, let vm = viewModel,
                  let episode = selectedEpisode, episode.id == newID,
                  episode.awaitsMediaDetail else { return }
            Task {
                let enriched = await vm.enrichedEpisode(for: episode)
                if selectedEpisode?.id == enriched.id {
                    selectedEpisode = enriched
                }
                // Settled either way (enrichedEpisode returns the input on failure): release the synopsis placeholder so it can't sit empty forever.
                settledEpisodeDetailIDs.insert(episode.id)
            }
        }
        .menuPresentation(isPresented: $isPresentingMoreDetails, panel: .plain) {
            DetailMoreOverlay(
                title: displayItem.name,
                // Veiled stays veiled: the reader is not a way around the spoiler rule, and the box
                // below the fold is where it gets lifted.
                synopsis: SpoilerReveal.isHidden(displayItem, dependencies: dependencies, appState: appState)
                    ? nil : displayOverview,
                facts: techFacts(),
                versionLabel: TechFacts.versionSubtitle(
                    for: displayItem,
                    sourceID: versionSelection.preferredSourceID(for: displayItem)
                ),
                isPresented: $isPresentingMoreDetails
            )
        }
        .alert(
            viewModel?.isPlayed == true
                ? "detail.markUnwatched.confirm.title"
                : "detail.markWatched.confirm.title",
            isPresented: $isConfirmingPlayedChange,
            presenting: viewModel
        ) { vm in
            Button(vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched") {
                Task { await vm.togglePlayed() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { vm in
            // No message rather than an invented one when the server sent no count: the title alone
            // still names the scope, and a number the client guessed at would be the one part of
            // this alert a viewer could not check.
            if let episodes = vm.item.recursiveItemCount, episodes > 0 {
                Text(
                    vm.isPlayed
                        ? "detail.markUnwatched.confirm.message \(episodes) \(vm.item.name)"
                        : "detail.markWatched.confirm.message \(episodes) \(vm.item.name)"
                )
            }
        }
        .menuPresentation(isPresented: $isPresentingDeleteSheet, panel: .plain) {
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
                                // The open episode panel is the view's own state, decoupled from the
                                // VM's next-up tracking refreshSeasons() just reconciled: if its
                                // season just went, Play would otherwise still read from a deleted
                                // episode (Audit 2026-09-25 BROWSE-7).
                                if let seasonID = selectedEpisode?.seasonId,
                                   !vm.seasons.contains(where: { $0.id == seasonID }) {
                                    selectedEpisode = nil
                                }
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

    /// The whole scrolling page. Extracted from `body` because the type checker gave up on it as one
    /// expression once the overlay took another argument, which is the usual signal that a SwiftUI
    /// body has grown past what it should hold. Same shape MovieDetailView already has.
    @ViewBuilder
    private func contentOverlay(vm: DetailViewModel) -> some View {
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
                // See MovieDetailView: with this line below the fold the page measures ~30 pt of
                // content down there, the trailing chrome adds 200, and tvOS scrolls 116 pt to park
                // the focused Play button. Up here the block measures zero, the chrome goes with it,
                // and the page is exactly one viewport and cannot be scrolled (Sodalite#146 round 2).
                if !hasBelowFoldSections(vm: vm), let caption = techFacts().caption {
                    DetailFileCaption(caption: caption)
                        .padding(.horizontal, -metrics.rowInset)
                }
            }
            .padding(.horizontal, metrics.rowInset)
            // Keyed on item + load state only, NOT genre count: on an instant-paint episode deep-link the series genres land post-paint, flipping the count rebuilt the panel and broke scroll-to-top back to Play. Genres fill in via in-place diff.
            .id("\(vm.item.id)-\(vm.isLoading)")
            .animation(.easeInOut(duration: 0.3), value: selectedEpisode?.id)
        }) {
            // Captured proxy lets player-dismiss scroll the outer ScrollView back to the episode row, else tvOS's scroll-focus-into-view runs against a not-yet-rendered state and jumps to the top.
            ScrollViewReader { outerProxy in
                VStack(alignment: .leading, spacing: 40) {
                    // No synopsis block here any more (Sodalite#146). Three lines of it sit in the
                    // first viewport and the whole of it is behind More Details, so a third copy
                    // under the fold was the page saying the same thing twice with a focus stop
                    // between. The season bar is the first stop now, and the up-move out of it is
                    // handled the way #53 measured: the secondaries leave the focus engine while
                    // focus is not in the action row.
                    if !vm.seasons.isEmpty {
                        seasonSection(vm: vm)
                            .id("episodeRow")
                    } else if vm.isLoadingSeasons {
                        // getSeasons in flight: skeleton tabs + episode row so it isn't a blank gap on a slow CDN. Swapped for the real section once seasons arrive.
                        seasonSectionSkeleton(vm: vm)
                            .id("episodeRow")
                    }

                    // Cast above Related (Sodalite#47): with the season/episode block over
                    // it, the cast row already sits far down the page for viewers who only
                    // want the people.
                    // Only the FIRST section below the fold redirects; see the movie page for the
                    // reasoning. Here the season block is almost always first, so these carry the
                    // flag for the show that has no seasons yet.
                    let seasonBlockIsFirst = !vm.seasons.isEmpty || vm.isLoadingSeasons
                    let hasCast = !(vm.item.people?.isEmpty ?? true)

                    if let people = vm.item.people, !people.isEmpty {
                        let cast = jellyfinCastMembers(
                            from: people,
                            imageService: dependencies.jellyfinImageService,
                            imageWidth: metrics.castImageWidth,
                            serverID: vm.item.serverID
                        )
                        MediaCastRow(
                            members: cast,
                            focusedID: $focusedCastID,
                            onSelect: { handlePersonTap($0) }
                        )
                        .onFocusMoveUp(active: !seasonBlockIsFirst) { playButtonFocused = true }
                        .onChange(of: focusedCastID) { _, newID in
                            aimFirstCastEntry(at: newID, in: cast)
                        }
                    }

                    // Sodalite#179. The show's extras, not an episode's, so they leave with the
                    // Trailer button when an episode takes the page.
                    let showsExtras = !isShowingEpisode && !vm.specialFeatures.isEmpty
                    if showsExtras {
                        HorizontalMediaRow(
                            title: "detail.extras",
                            items: vm.specialFeatures,
                            imageURLProvider: { dependencies.jellyfinImageService.episodeThumbnailURL(for: $0) },
                            fallbackURLProvider: { _ in vm.backdropURL(for: vm.item) },
                            onItemSelected: { extra in
                                playItem = extra
                                playFromBeginning = true
                                playOriginatedFromPlayButton = false
                                showPlayer = true
                            },
                            cardStyle: .landscape
                        )
                        .onFocusMoveUp(active: !seasonBlockIsFirst && !hasCast) { playButtonFocused = true }
                    }

                    if !vm.similarItems.isEmpty {
                        HorizontalMediaRow(
                            title: "detail.similar",
                            items: vm.similarItems,
                            imageURLProvider: { vm.posterURL(for: $0) },
                            onItemSelected: { navigateToItem = $0 },
                            cardStyle: .poster
                        )
                        .onFocusMoveUp(active: !seasonBlockIsFirst && !hasCast && !showsExtras) { playButtonFocused = true }
                    }

                    // Same split the search screen teaches: what the server has on top, what it
                    // would have to fetch below, under the header the catalog already uses.
                    if !vm.catalogSimilar.isEmpty {
                        SeerrHorizontalMediaRow(
                            title: "search.section.catalog",
                            items: vm.catalogSimilar,
                            onItemSelected: { navigateToSeerrRequest = $0 }
                        )
                        .onFocusMoveUp(active: !seasonBlockIsFirst && !hasCast && !showsExtras && vm.similarItems.isEmpty) {
                            playButtonFocused = true
                        }
                    }

                    // Sodalite#146: one non-focusable line closing the page with what the
                    // file actually is, in place of the strip that cost a third of a screen
                    // for the same facts. It follows the episode on screen. On a page with no
                    // sections at all it moves into the first viewport, see `hasBelowFoldSections`.
                    if hasBelowFoldSections(vm: vm), let caption = techFacts().caption {
                        DetailFileCaption(caption: caption)
                            .animation(.easeInOut(duration: 0.3), value: selectedEpisode?.id)
                    }
                }
                .onAppear {
                    episodeRowScrollProxy = outerProxy
                }
            }
        }
        .modifier(PageScrollProxyCapture(proxy: $pageScrollProxy))
        .transition(.opacity)
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

            // Metadata line with the series tagline set against it, in both modes so the episode
            // panel matches the root; genres and studios moved into More Details (Sodalite#146
            // round 2).
            DetailInfoRows(
                item: vm.item,
                hasFullDetail: vm.hasFullDetail
            ) {
                if isShowingEpisode {
                    // Single metadata line (runtime + series genres). S/E pair left the panel (Sodalite#15 round 6) since the play-button subtitle already carries it; keeps the episode panel at title + one line.
                    // The format pills join that line where it has the width, so the episode panel
                    // stays at title + one line. Portrait is the exception: the panel is one narrow
                    // column there and the pills pushed it past the screen edge (Sodalite#145,
                    // measured on the iPhone 2026-09-14).
                    if isPhonePortrait {
                        VStack(alignment: .leading, spacing: 8) {
                            episodeLine(vm: vm)
                            episodeBadges()
                        }
                    } else {
                        HStack(spacing: 12) {
                            episodeLine(vm: vm)
                            episodeBadges()
                        }
                    }
                } else {
                    ItemMetadataRow(item: vm.item, showRuntime: false, extras: seasonCount(vm: vm))
                }
            }

            // Sodalite#146: series synopsis in the series state, the episode's own in episode state,
            // which is what displayItem/displayOverview already resolve for the box below the fold.
            DetailHeroSynopsis(
                text: displayOverview,
                isPending: overviewMayStillLand,
                spoilerItem: displayItem
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The movie page's number, and the phone-portrait branch with it: the series panel was a
        // flat 30 on every tier, so on a phone the two pages inset their text differently by 14 pt
        // (Sodalite#146 round 3).
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Season count as a metadata segment, and no segment at all when the server gave none: a row
    /// handed an EmptyView still counts it as a segment and puts a separator in front, which left
    /// the line ending on a dot with nothing behind it.
    private func seasonCount(vm: DetailViewModel) -> [AnyView] {
        guard let count = vm.item.childCount, count > 0 else { return [] }
        return [AnyView(Text("detail.seasonCount \(count)"))]
    }

    @ViewBuilder
    private func episodeLine(vm: DetailViewModel) -> some View {
        if let line = episodeMetadataLine(vm: vm) {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func episodeBadges() -> some View {
        let pills = formatBadgePills()
        if !pills.isEmpty {
            FormatBadgeRow(pills: pills)
        }
    }

    /// Sodalite#145. Episode mode only: a series root has no streams of its own, and a badge sampled
    /// from one episode would speak for the rest of them. Reads `displayItem`, so the pills follow
    /// the episode on screen and the version the tech strip below is describing.
    private func formatBadgePills() -> [String] {
        guard isShowingEpisode else { return [] }
        return FormatBadgeRow.pills(
            for: displayItem,
            sourceID: versionSelection.preferredSourceID(for: displayItem),
            enabled: dependencies.appearancePreferences.showDetailBadges,
            carriesHDR10Plus: dependencies.hdr10PlusProbeStore.carriesHDR10Plus(
                item: displayItem,
                sourceID: versionSelection.preferredSourceID(for: displayItem))
        )
    }

    /// AE#579, the episode state only: the probe follows the episode on screen, and a series root
    /// has no file to open. Keyed on the resolved source, because an episode opened from Home or
    /// search arrives slim and only grows its media sources when the detail fetch lands.
    private var hdr10PlusProbeKey: String {
        guard isShowingEpisode else { return "-" }
        let item = displayItem
        let source = item.effectiveMediaSource(id: versionSelection.preferredSourceID(for: item))
        return [item.id, source?.id ?? "-"].joined(separator: "|")
    }

    /// displayItem, so the episode state asks about the episode: the policy ignores a series, which
    /// is what keeps a show's own synopsis visible while its episodes are veiled.
    private var isSynopsisVeiled: Bool {
        SpoilerReveal.isHidden(displayItem, dependencies: dependencies, appState: appState)
    }

    /// Everything the page can say about the copy it is describing, for the reader and the caption
    /// line alike, so the two cannot describe different files. displayItem, so both follow the
    /// episode on screen.
    /// Whether anything below the fold is a section rather than the closing caption line. It decides
    /// where that line is drawn, and through it whether the page is scrollable at all. The season
    /// block counts while it is still loading: its skeleton holds the same room the real one will.
    private func hasBelowFoldSections(vm: DetailViewModel) -> Bool {
        !vm.seasons.isEmpty || vm.isLoadingSeasons
            || !(vm.item.people?.isEmpty ?? true)
            || (!isShowingEpisode && !vm.specialFeatures.isEmpty)
            || !vm.similarItems.isEmpty
            || !vm.catalogSimilar.isEmpty
    }

    private func techFacts() -> TechFacts {
        TechFacts.resolve(item: displayItem, sourceID: versionSelection.preferredSourceID(for: displayItem))
    }

    /// Episode panel's single metadata line, which is the episode's runtime and nothing else since
    /// the genres left the page (Sodalite#146 round 2): keeping them here would have been the one
    /// place they survived, on the state that has the least room for them. nil when there is no
    /// runtime, so the line collapses rather than drawing empty.
    private func episodeMetadataLine(vm: DetailViewModel) -> String? {
        guard let runtime = selectedEpisode?.runTimeTicks, runtime > 0 else { return nil }
        return runtime.ticksToDurationDisplay
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
                        .focusSuppressed(focusedAction == nil)
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
        .focused($focusedAction, equals: .play)
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
            // First after Play, same as movie detail: the version belongs to the
            // episode Play would start, so it rides with playTarget and disappears with it. Series
            // roots take their target from the slim episode list, which carries no MediaSources, so
            // in practice it appears in the episode panel once enrichment lands (Sodalite#139).
            if let target = playTarget(vm: vm),
               VersionSelection.isOffered(for: target) {
                let sources = target.selectableMediaSources
                GlassActionButton(
                    title: "detail.version.button",
                    systemImage: "film.stack",
                    subtitle: versionSelection.resolvedSource(for: target).map(sources.distinguishingLabel),
                    alwaysShowsLabel: VersionSelection.labelStaysOpen,
                    action: {
                        versionChoice = VersionPickerChoice(
                            item: target,
                            sources: sources,
                            selectedID: versionSelection.resolvedSource(for: target)?.id
                        )
                    }
                )
                .focused($focusedAction, equals: .version)
            }

            // Shuffle whole series (server SortBy=Random scoped by series id). Hidden in the episode panel.
            if !isShowingEpisode {
                GlassActionButton(
                    title: "action.shuffle",
                    systemImage: "shuffle",
                    // Spinner on tap (VideoShuffleQueue.build lands a few hundred ms later), else the row sits inert until showPlayer flips.
                    isLoading: isShuffleLoading,
                    action: {
                        guard let userID = sessionUserID else { return }
                        let seriesID = vm.item.id
                        isShuffleLoading = true
                        Task {
                            let queue = await VideoShuffleQueue.build(
                                parentID: seriesID,
                                itemTypes: [.episode],
                                service: session.libraryService,
                                userID: userID
                            )
                            isShuffleLoading = false
                            guard let first = queue.first else { return }
                            playItem = first
                            playQueue = queue
                            playFromBeginning = true
                            playOriginatedFromPlayButton = true
                            showPlayer = true
                        }
                    }
                )
                .focused($focusedAction, equals: .shuffle)
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
                .focused($focusedAction, equals: .replay)
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
                .focused($focusedAction, equals: .trailer)
            }

            if !isShowingEpisode {
                GlassActionButton(
                    title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                    action: { Task { await vm.toggleFavorite() } }
                )
                .focused($focusedAction, equals: .favorite)
            }

            if !isShowingEpisode {
                GlassActionButton(
                    title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                    systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                    action: { isConfirmingPlayedChange = true }
                )
                .focused($focusedAction, equals: .watched)
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
                .focused($focusedAction, equals: .spoiler)
                .contextMenu { spoilerRuleMenu(seriesID: seriesID) }
            }

            if isShowingEpisode {
                // `tv`, not `xmark` (Sodalite#146): the glyph said "close this panel" while the
                // label said "show the series", and only one of the two is what pressing it does.
                GlassActionButton(
                    title: "detail.showSeries",
                    systemImage: "tv",
                    action: { closeEpisodeState() }
                )
                .focused($focusedAction, equals: .goToShow)
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
                .focused($focusedAction, equals: .favorite)
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
                .focused($focusedAction, equals: .watched)

                #if os(iOS)
                if session.allowsDeleteAndDownload {
                    DownloadActionButton(item: ep, target: $downloadTarget)
                }
                #endif
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
                .focused($focusedAction, equals: .request)
            }

            // Last of the informational controls, and the page's only route to the full synopsis
            // and the technical detail (Sodalite#146).
            GlassActionButton(
                title: isSynopsisVeiled ? "spoiler.reveal" : "detail.moreDetails",
                systemImage: isSynopsisVeiled ? "eye.circle" : "info.circle",
                action: {
                    // One label, one meaning at a time. While the synopsis is veiled this is what
                    // lifts it, which is the job the focusable box below the fold used to do; the
                    // reader would otherwise be a way around the spoiler rule (Sodalite#50).
                    //
                    // `eye.circle`, not `eye`: the series row already carries a plain `eye` for the
                    // per-SERIES rule, and two identical glyphs in one row would be a one-off reveal
                    // and a standing setting wearing the same face. Circular, so it reads as this
                    // button in another state rather than as a different control.
                    if isSynopsisVeiled {
                        SpoilerReveal.reveal(displayItem, dependencies: dependencies, appState: appState)
                    } else {
                        isPresentingMoreDetails = true
                    }
                }
            )
            .focused($focusedAction, equals: .moreDetails)

            // Delete last, matching MovieDetailView, so the destructive action sits furthest from Play.
            if canDelete(displayItem) && !isShowingEpisode {
                GlassActionButton(
                    title: "detail.delete.button",
                    systemImage: "trash",
                    isDestructive: true,
                    action: { isPresentingDeleteSheet = true }
                )
                .focused($focusedAction, equals: .delete)
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

    /// Sodalite#146: the label is the state, and on a fresh target it also names the episode, which
    /// is the one thing the show hero has to say before the press. A special with no index numbers
    /// has no shorthand to name, and then the plain label stands.
    private func playTitle(vm: DetailViewModel) -> LocalizedStringKey {
        guard let target = playTarget(vm: vm) else { return "detail.play" }
        switch playState(for: target) {
        case .resume: return "detail.resume"
        case .again: return "detail.playAgain"
        case .fresh:
            let shorthand = episodeShorthand(for: target)
            return shorthand.isEmpty ? "detail.play" : "detail.play.episode.named \(shorthand)"
        }
    }

    /// Play-button subtitle: "S1, E5 · 42 min" when resuming, "S1, E5" on a re-watch, and nothing at
    /// all when fresh, because the title already named the episode. Time LEFT rather than the
    /// position reached, the same thing the bar above it and every card in the app say.
    private func playButtonSubtitle(vm: DetailViewModel) -> String? {
        guard let target = playTarget(vm: vm) else { return nil }
        guard playState(for: target) != .fresh || episodeShorthand(for: target).isEmpty else { return nil }

        var parts: [String] = []
        let episodeLabel = episodeShorthand(for: target)
        if !episodeLabel.isEmpty {
            parts.append(episodeLabel)
        }
        if let remaining = target.resumeRemainingTicks?.ticksToDurationDisplay {
            parts.append(remaining)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Leaving the episode state. One function because Menu and the Go to Show button have to do
    /// the same thing (Sodalite#146); on tvOS Menu used to dismiss the whole detail cover from here,
    /// so a viewer who opened an episode lost the show page to get out of it.
    private func closeEpisodeState() {
        withAnimation(.easeInOut(duration: 0.3)) { selectedEpisode = nil }
        episodeOrigin.returnedToSeries()
    }

    private func playState(for target: JellyfinItem) -> PlayActionState {
        PlayActionState.resolve(positionTicks: target.userData?.playbackPositionTicks,
                                isPlayed: target.userData?.played == true)
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

    /// Where a move down into the cast row lands; see `MovieDetailView.aimFirstCastEntry` for why the
    /// geometric landing is arbitrary here and why only the first entry is corrected.
    private func aimFirstCastEntry(at newID: String?, in cast: [CastMember]) {
        guard let newID, !castEntryAimed else { return }
        castEntryAimed = true
        guard let first = cast.first?.id, newID != first else { return }
        DispatchQueue.main.async { focusedCastID = first }
    }

    /// Resolve a cast member to a TMDB person id and open the person page; inert when the server has no TMDB id.
    /// The series id, not the selected episode's: TMDB credits a person on the show (Sodalite#143).
    private func handlePersonTap(_ member: CastMember) {
        navigateToPerson = PersonRoute(
            member: member,
            sourceTMDBID: viewModel?.item.tmdbID ?? item.tmdbID
        )
    }

    // MARK: - Season Section

    /// The selected season's synopsis, when the library has one. The box and the focus routing read the same accessor, so an up-move can never be aimed at a box that is not on screen.
    private func seasonOverview(vm: DetailViewModel) -> String? {
        guard let overview = vm.selectedSeason?.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty else { return nil }
        return overview
    }

    /// The long-press menu on an episode card. A function because the two platforms attach it
    /// differently: only touch gets a preview, and only because of the ring (see the call site).
    @ViewBuilder
    private func episodeContextMenu(_ episode: JellyfinItem, vm: DetailViewModel) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedEpisode = episode
            }
            episodeOrigin.openedFromStrip()
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

        #if os(iOS)
        if session.allowsDeleteAndDownload, dependencies.downloadManager != nil {
            if dependencies.downloadStore.completedItem(episode.id) != nil {
                Button {
                    streamFromServer = true
                    requestPlay(episode, fromBeginning: false, fromPlayButton: false)
                } label: {
                    Label("downloads.action.streamFromServer", systemImage: "network")
                }
            }
            if dependencies.downloadStore.item(episode.id) == nil {
                Button {
                    downloadTarget = .item(episode)
                } label: {
                    Label("downloads.action.download", systemImage: "arrow.down.circle")
                }
            } else if let manager = dependencies.downloadManager {
                Button(role: .destructive) {
                    Task { await manager.cancel(itemID: episode.id) }
                } label: {
                    Label(dependencies.downloadStore.completedItem(episode.id) != nil
                          ? "downloads.action.remove" : "downloads.action.cancel", systemImage: "trash")
                }
            }
        }
        #endif

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

    /// One card, built once, so the row and the long-press preview cannot drift apart.
    private func episodeCard(_ episode: JellyfinItem, vm: DetailViewModel, playTargetID: String?) -> some View {
        EpisodeLandscapeCard(
            episode: episode,
            imageURL: dependencies.jellyfinImageService.episodeThumbnailURL(for: episode),
            isPlayTarget: playTargetID == episode.id,
            isFocused: focusedEpisodeID == episode.id,
            isPlayed: vm.isPlayed(episode),
            isFavorite: vm.isFavorite(episode),
            justMarkedPlayed: vm.wasMarkedPlayedInSession(episode)
        )
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
                            // Up out of the first section below the fold has to be REDIRECTED, not
                            // merely resolved, exactly as on the movie page. The secondaries are out
                            // of the focus engine while focus is not in the action row, so Play is
                            // the only candidate left, and from a tab past the row's width it is too
                            // far sideways for the engine to reach at all: the move simply does not
                            // happen, and the page is a dead end until the viewer walks back to the
                            // leftmost tab (Sodalite#146 round 2, reported on a device). On the tab
                            // and not on the block around it: an `onMoveCommand` out there would
                            // also catch the up-moves out of the episode row and the season
                            // synopsis, which have their own, nearer destinations.
                            .onFocusMoveUp(active: true) { playButtonFocused = true }
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
                                #if os(iOS)
                                if session.allowsDeleteAndDownload, dependencies.downloadManager != nil {
                                    Button {
                                        downloadTarget = .season(
                                            seriesID: vm.item.id, seasonID: season.id,
                                            episodes: vm.selectedSeasonID == season.id ? vm.episodes : [])
                                    } label: {
                                        Label("downloads.action.downloadSeason", systemImage: "arrow.down.circle")
                                    }
                                }
                                #endif
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
                // Resolved once for the row: the ring reads the same target the Play button acts on, so the two cannot name different episodes.
                let playTargetID = playTarget(vm: vm)?.id
                ScrollViewReader { episodeProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: hSizeClass == .compact ? metrics.itemSpacing : 24) {
                            ForEach(vm.episodes) { episode in
                                VStack(alignment: .leading, spacing: 10) {
                                    Button {
                                        requestPlay(episode, fromBeginning: false, fromPlayButton: false)
                                    } label: {
                                        episodeCard(episode, vm: vm, playTargetID: playTargetID)
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
                                    // The system preview, deliberately: it snapshots the real view
                                    // in the real environment, so it carries the accent, the theme
                                    // and the page's own ground. A hand-built one is a second view
                                    // hierarchy outside all three, and it showed: default blue and a
                                    // grey platter (2026-09-14). What the snapshot cannot do is
                                    // reach outside the card's bounds, which is why the ring now
                                    // lives inside them (see EpisodeCardStroke.ringMargin).
                                    .contextMenu { episodeContextMenu(episode, vm: vm) }

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
                    // No animation: the row is behind the player, and an animated scroll is exactly
                    // what leaves the target unrendered for a moment.
                    .onChange(of: episodeRowFollowID) { _, target in
                        guard let target, vm.episodes.contains(where: { $0.id == target }) else { return }
                        episodeProxy.scrollTo(target, anchor: .center)
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

    /// While a player session is up, the episode it is on wins over next-up: a session that rolled into
    /// the next season rebuilds or re-seats this row, and next-up still names the episode it was loaded with.
    private func scrollToCurrentEpisode(proxy: ScrollViewProxy, vm: DetailViewModel) {
        guard let currentID = episodeRowFollowID ?? vm.currentEpisodeID,
              vm.episodes.contains(where: { $0.id == currentID }) else { return }
        deferOnMain(by: 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}
