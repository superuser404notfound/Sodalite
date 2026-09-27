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
    /// Which version the page describes and Play starts; the viewer sets it from the version button (Sodalite#139).
    @State private var versionSelection = VersionSelection()
    @State private var showTrailer = false
    @State private var trailerItem: JellyfinItem?
    @State private var isPresentingDeleteSheet: Bool = false
    @State private var isPresentingMoreDetails = false
    @FocusState private var playButtonFocused: Bool
    /// Which control in the action row holds focus, nil while focus is anywhere else on the page.
    /// The secondaries leave the focus engine for that time, so an up-move out of the content can
    /// only land on Play (Sodalite#53, and #146 once the overview box that used to answer this went
    /// away). See `DetailAction`.
    @FocusState private var focusedAction: DetailAction?
    /// Which cast card holds focus, for the row's entry aim (Sodalite#146 round 2).
    @FocusState private var focusedCastID: String?
    /// One-shot, so only the row's FIRST entry is aimed; after that it remembers where the viewer
    /// left it, the way every other row on tvOS does.
    @State private var castEntryAimed = false
    /// Gates the isLoading crossfade so it stays inert during the cover's present transition. The viewModel is built lazily in onAppear, so isLoading flips several times (nil->false->true->false) WHILE the fullScreenCover is dissolving in; animating those flips interpolates the content's not-yet-laid-out frame (origin top-left) and reads as an ugly fly-in. Enabled ~0.35s after appear so the later, deliberate slow-server spinner->content fade still animates.
    @State private var didSettleIn = false

    let item: JellyfinItem
    /// TopShelf playAction: fire the primary play action once, as soon as full detail has settled.
    var autoPlay: Bool = false
    @State private var didAutoPlay = false

    /// Whether this page offers deletion at all, and the item's own `CanDelete` is the whole answer
    /// wherever the server sent it (Sodalite#146). Jellyfin computes that field for THIS user from
    /// EnableContentDeletion OR the item's library being listed in EnableContentDeletionFromFolders,
    /// and `BaseItem.IsAuthorizedToDelete` never consults IsAdministrator. Keeping the account policy
    /// in front of it hid the trash can from precisely the setup the field exists for: a non-admin
    /// account granted deletion on one library. The policy remains the fallback for a response
    /// without the field, read from AppState.activeUser so a profile switch updates visibility.
    private func canDelete(_ item: JellyfinItem) -> Bool {
        if let serverAnswer = item.canDelete { return serverAnswer }
        return appState.activeUser?.canDeleteContent == true
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
                    preferredMediaSourceID: versionSelection.preferredSourceID(for: viewModel?.item ?? item)
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
        // false precedes the detail round trip, so the autoplay would launch off the navigating
        // snapshot rather than the fetched item.
        .task(id: viewModel?.hasFullDetail) {
            guard autoPlay, !didAutoPlay, viewModel?.hasFullDetail == true else { return }
            didAutoPlay = true
            requestPlay(fromBeginning: false)
        }
        // AE#579. After the detail round trip, because the media sources it needs arrive with it,
        // and again when the viewer picks another version.
        .task(id: hdr10PlusProbeKey) {
            guard let item = viewModel?.item else { return }
            await dependencies.hdr10PlusProbeStore.probeIfNeeded(
                item: item,
                sourceID: versionSelection.preferredSourceID(for: item))
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
                personName: route.name,
                sourceTMDBID: route.sourceTMDBID
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
        .menuPresentation(isPresented: $isPresentingMoreDetails, panel: .plain) {
            if let vm = viewModel {
                DetailMoreOverlay(
                    title: vm.item.name,
                    // Veiled stays veiled: the reader is not a way around the spoiler rule, and the
                    // box below the fold is where it gets lifted.
                    synopsis: SpoilerReveal.isHidden(vm.item, dependencies: dependencies, appState: appState)
                        ? nil : vm.item.overview,
                    facts: techFacts(vm: vm),
                    versionLabel: TechFacts.versionSubtitle(
                        for: vm.item,
                        sourceID: versionSelection.preferredSourceID(for: vm.item)
                    ),
                    isPresented: $isPresentingMoreDetails
                )
            }
        }
        .menuPresentation(isPresented: $isPresentingDeleteSheet, panel: .plain) {
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
                // Sodalite#146 round 2. A page whose ONLY content below the fold is this one
                // non-focusable line has no business having a fold at all, and the difference is not
                // cosmetic. With the line down there the block measures ~30 pt, the trailing chrome
                // adds 200, and tvOS scrolls the page 116 pt to park the focused Play button where
                // it wants it. With the line up here the block measures zero, the chrome is
                // suppressed with it, the content is exactly one viewport and the page cannot be
                // scrolled at all. Measured: that is the last shape that still moved once the
                // chrome stopped being offered to pages that have real rows.
                    if !hasBelowFoldSections(vm: vm), let caption = techFacts(vm: vm).caption {
                        DetailFileCaption(caption: caption)
                            .padding(.horizontal, -metrics.rowInset)
                    }
                }
                .padding(.horizontal, metrics.rowInset)
            }) {
                // No synopsis block here any more (Sodalite#146). Three lines of it sit in the
                // first viewport and the whole of it is behind More Details, so a third copy under
                // the fold was the page saying the same thing twice with a focus stop between.
                // Up out of the FIRST section below the fold has to be REDIRECTED, not merely
                // resolved. With the secondaries out of the focus engine Play is the only candidate
                // left, and from a card far to the right it is too far sideways for the engine to
                // reach at all, so the move simply does not happen (reported on the Apple TV,
                // 2026-09-14). Sections further down move up into their predecessor, which is a
                // full-width row, and must NOT redirect or an up-move from Related would skip the
                // cast row. Hence `active:` rather than a modifier on one row.
                let hasCast = !(vm.item.people?.isEmpty ?? true)

                if let people = vm.item.people, !people.isEmpty {
                    let cast = jellyfinCastMembers(
                        from: people,
                        imageService: dependencies.jellyfinImageService,
                        imageWidth: metrics.castImageWidth
                    )
                    MediaCastRow(
                        members: cast,
                        focusedID: $focusedCastID,
                        onSelect: { handlePersonTap($0) }
                    )
                    .onFocusMoveUp(active: true) { playButtonFocused = true }
                    .onChange(of: focusedCastID) { _, newID in
                        aimFirstCastEntry(at: newID, in: cast)
                    }
                }

                if !vm.similarItems.isEmpty {
                    HorizontalMediaRow(
                        title: "detail.similar",
                        items: vm.similarItems,
                        imageURLProvider: { vm.posterURL(for: $0) },
                        onItemSelected: { navigateToItem = $0 },
                        cardStyle: .poster
                    )
                    .onFocusMoveUp(active: !hasCast) { playButtonFocused = true }
                }

                // Same split the search screen teaches: what the server has on top, what it would have
                // to fetch below, under the header the catalog already uses.
                if !vm.catalogSimilar.isEmpty {
                    SeerrHorizontalMediaRow(
                        title: "search.section.catalog",
                        items: vm.catalogSimilar,
                        onItemSelected: { navigateToSeerrRequest = $0 }
                    )
                    .onFocusMoveUp(active: !hasCast && vm.similarItems.isEmpty) { playButtonFocused = true }
                }

                // Sodalite#146, after Infuse: one non-focusable line closing the page with what the
                // file actually is. The tech strip that used to carry these facts is gone; this is
                // the part of it worth keeping in sight, and it costs a line instead of a third of
                // a screen. On a page with no rows at all it moves into the first viewport instead,
                // see `hasBelowFoldSections`.
                if hasBelowFoldSections(vm: vm), let caption = techFacts(vm: vm).caption {
                    DetailFileCaption(caption: caption)
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

            // Metadata line with the tagline set against it; genres and studios moved into More
            // Details (Sodalite#146 round 2).
            DetailInfoRows(
                item: vm.item,
                hasFullDetail: vm.hasFullDetail
            ) {
                // Portrait puts the pills on a line of their own: the panel is one narrow column
                // there, and four of them on the metadata line pushed it past the screen edge and
                // dragged the studios line out with it (measured on the iPhone, 2026-09-14).
                if isPhonePortrait {
                    VStack(alignment: .leading, spacing: 8) {
                        ItemMetadataRow(item: vm.item)
                        let pills = formatBadgePills(vm: vm)
                        if !pills.isEmpty {
                            FormatBadgeRow(pills: pills)
                        }
                    }
                } else {
                    ItemMetadataRow(item: vm.item, badges: formatBadges(vm: vm))
                }
            }

            // Sodalite#146: the plot belongs in the viewport the viewer actually meets. The box
            // below the fold keeps the full text; this is the teaser that decides whether they
            // scroll to it.
            DetailHeroSynopsis(
                text: vm.item.overview,
                isPending: !vm.hasFullDetail,
                spoilerItem: vm.item
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Sodalite#145. Reads the version the page is showing, the same source id the tech strip below
    /// uses, so the pills cannot describe a copy the viewer did not pick.
    private func formatBadges(vm: DetailViewModel) -> [AnyView] {
        FormatBadgeRow.extras(
            for: vm.item,
            sourceID: versionSelection.preferredSourceID(for: vm.item),
            enabled: dependencies.appearancePreferences.showDetailBadges,
            carriesHDR10Plus: carriesHDR10Plus(vm: vm)
        )
    }

    /// The same pills for the portrait layout, which places the row itself instead of handing it to
    /// the metadata line as a segment.
    private func formatBadgePills(vm: DetailViewModel) -> [String] {
        FormatBadgeRow.pills(
            for: vm.item,
            sourceID: versionSelection.preferredSourceID(for: vm.item),
            enabled: dependencies.appearancePreferences.showDetailBadges,
            carriesHDR10Plus: carriesHDR10Plus(vm: vm)
        )
    }

    /// The file the probe would open. Keyed on the resolved source rather than on `hasFullDetail`,
    /// because a page can render from a slim item that carries no media sources at all: the id only
    /// appears once the detail round trip has landed, and that is the moment there is something to
    /// ask about.
    private var hdr10PlusProbeKey: String {
        guard let item = viewModel?.item else { return "-" }
        let source = item.effectiveMediaSource(id: versionSelection.preferredSourceID(for: item))
        return [item.id, source?.id ?? "-"].joined(separator: "|")
    }

    /// AE#579. The server cannot see an in-band HDR10+ SEI, so the page asks the engine once per
    /// version and repaints the pill if the answer comes back positive.
    private func carriesHDR10Plus(vm: DetailViewModel) -> Bool {
        dependencies.hdr10PlusProbeStore.carriesHDR10Plus(
            item: vm.item,
            sourceID: versionSelection.preferredSourceID(for: vm.item))
    }

    private func isSynopsisVeiled(vm: DetailViewModel) -> Bool {
        SpoilerReveal.isHidden(vm.item, dependencies: dependencies, appState: appState)
    }

    /// Everything the page can say about the copy it is describing. Read once per body pass and
    /// handed to both the reader and the caption line, so the two cannot describe different files.
    /// Whether anything below the fold is a section rather than the closing caption line. It decides
    /// where that line is drawn, and through it whether the page is scrollable at all.
    private func hasBelowFoldSections(vm: DetailViewModel) -> Bool {
        !(vm.item.people?.isEmpty ?? true) || !vm.similarItems.isEmpty || !vm.catalogSimilar.isEmpty
    }

    private func techFacts(vm: DetailViewModel) -> TechFacts {
        TechFacts.resolve(item: vm.item, sourceID: versionSelection.preferredSourceID(for: vm.item))
    }

    /// Play starts the version the page shows. It used to open the picker instead, which put a
    /// question between the viewer and every start and told nobody it was coming (Sodalite#139).
    private func requestPlay(fromBeginning: Bool) {
        playFromBeginning = fromBeginning
        showPlayer = true
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
                        .focusSuppressed(focusedAction == nil)
                }
            }
        }
    }

    private func primaryActionButton(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: playButtonTitle(vm: vm),
            systemImage: "play.fill",
            isProminent: true,
            subtitle: resumeRemaining(vm: vm),
            progressFraction: playProgressFraction(vm: vm),
            action: {
                requestPlay(fromBeginning: false)
            }
        )
        .focused($focusedAction, equals: .play)
        .focused($playButtonFocused)
    }

    @ViewBuilder
    private func secondaryActionButtons(vm: DetailViewModel) -> some View {
            // First after Play, and always labelled: this is a play decision, and a version button
            // that collapses to a bare glyph hides the one thing it is there to say. Only a
            // multi-source item grows it, so its presence answers "does this have more than one
            // version" before it is ever pressed (Sodalite#139).
            if VersionSelection.isOffered(for: vm.item), let sources = vm.item.mediaSources {
                GlassActionButton(
                    title: "detail.version.button",
                    systemImage: "film.stack",
                    subtitle: versionSelection.resolvedSource(for: vm.item)?.versionLabel,
                    alwaysShowsLabel: true,
                    action: {
                        versionChoice = VersionPickerChoice(
                            item: vm.item,
                            sources: sources,
                            selectedID: versionSelection.resolvedSource(for: vm.item)?.id
                        )
                    }
                )
                .focused($focusedAction, equals: .version)
            }

            if hasProgress(vm: vm) {
                GlassActionButton(
                    title: "detail.replay",
                    systemImage: "arrow.counterclockwise",
                    action: {
                        requestPlay(fromBeginning: true)
                    }
                )
                .focused($focusedAction, equals: .replay)
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
                .focused($focusedAction, equals: .trailer)
            }

            if vm.item.type != .episode {
                GlassActionButton(
                    title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                    action: { Task { await vm.toggleFavorite() } }
                )
                .focused($focusedAction, equals: .favorite)
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
                .focused($focusedAction, equals: .goToShow)
            }

            // No "Request in Seerr" on movie detail: the movie is already in Jellyfin. The button stays on series detail for continuing shows.

            GlassActionButton(
                title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                action: { Task { await vm.togglePlayed() } }
            )
            .focused($focusedAction, equals: .watched)

            // Last of the informational controls, and the page's only route to the full synopsis
            // and the technical detail (Sodalite#146).
            GlassActionButton(
                title: isSynopsisVeiled(vm: vm) ? "spoiler.reveal" : "detail.moreDetails",
                systemImage: isSynopsisVeiled(vm: vm) ? "eye.circle" : "info.circle",
                action: {
                    // One label, one meaning at a time. While the synopsis is veiled this is what
                    // lifts it, which is the job the focusable box below the fold used to do; the
                    // reader would otherwise be a way around the spoiler rule (Sodalite#50).
                    //
                    // `eye.circle`, not `eye`: the series row already carries a plain `eye` for the
                    // per-SERIES rule, and two identical glyphs in one row would be a one-off reveal
                    // and a standing setting wearing the same face. Circular, so it reads as this
                    // button in another state rather than as a different control.
                    if isSynopsisVeiled(vm: vm) {
                        SpoilerReveal.reveal(vm.item, dependencies: dependencies, appState: appState)
                    } else {
                        isPresentingMoreDetails = true
                    }
                }
            )
            .focused($focusedAction, equals: .moreDetails)

            // Episodes only reach here via DetailRouterView's no-parent-series fallback; per-episode deletion isn't supported (delete lives on series detail, matching SeriesDetailView's !isShowingEpisode guard).
            if canDelete(vm.item) && vm.item.type != .episode {
                GlassActionButton(
                    title: "detail.delete.button",
                    systemImage: "trash",
                    isDestructive: true,
                    action: { isPresentingDeleteSheet = true }
                )
                .focused($focusedAction, equals: .delete)
            }
    }

    // MARK: - Helpers

    private func hasProgress(vm: DetailViewModel) -> Bool {
        if let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0 { return true }
        return false
    }

    /// Sodalite#146: the label is the state. A finished title used to read "Play", which is true and
    /// says nothing; naming the replay is what tells the viewer they have seen this without their
    /// having to find the watched check in the row below.
    private func playButtonTitle(vm: DetailViewModel) -> LocalizedStringKey {
        switch PlayActionState.resolve(positionTicks: vm.item.userData?.playbackPositionTicks,
                                       isPlayed: vm.isPlayed) {
        case .fresh: "detail.play"
        case .resume: "detail.resume"
        case .again: "detail.playAgain"
        }
    }

    /// Time left, not the position reached (Sodalite#146). The button draws a progress bar and so
    /// does every card in the app, and the card's label beside it has read "42 min" since
    /// Sodalite#99, so a timestamp here was the one place answering a different question. No "left"
    /// wrapper for the same reason the cards carry none: the bar says what the number counts.
    private func resumeRemaining(vm: DetailViewModel) -> String? {
        vm.item.resumeRemainingTicks?.ticksToDurationDisplay
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

    /// Open the person page. Jellyfin cast carries no TMDB id, so the page resolves one itself and
    /// gets this movie's id along for the same-name tie-break (Sodalite#143).
    /// Where a move down into the cast row lands. tvOS resolves it geometrically from the centre of
    /// whatever had focus, so an entry from a button halfway along the action row lands halfway along
    /// the cast row, and the column then travels on into Related (Sodalite#146 round 2). Nothing in
    /// the row has been visited at that point, so there is no remembered place to honour and the
    /// arbitrary one is simply arbitrary.
    ///
    /// Only the first entry is corrected. Redirecting every entry would also undo the row's own
    /// memory, so coming back up out of Related would lose the card the viewer was on, which is not
    /// what anyone asked for and not what tvOS does anywhere else.
    private func aimFirstCastEntry(at newID: String?, in cast: [CastMember]) {
        guard let newID, !castEntryAimed else { return }
        castEntryAimed = true
        guard let first = cast.first?.id, newID != first else { return }
        // A @FocusState write made synchronously inside its own onChange is dropped on tvOS; a hop
        // through the main queue is honoured (the season bar carries the same note).
        DispatchQueue.main.async { focusedCastID = first }
    }

    private func handlePersonTap(_ member: CastMember) {
        navigateToPerson = PersonRoute(
            member: member,
            sourceTMDBID: viewModel?.item.tmdbID ?? item.tmdbID
        )
    }
}
