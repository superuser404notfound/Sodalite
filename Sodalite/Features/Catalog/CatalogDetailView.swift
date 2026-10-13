import SwiftUI

struct CatalogDetailView: View {
    let media: SeerrMedia
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    @State private var movieDetail: SeerrMovieDetail?
    @State private var tvDetail: SeerrTVDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// The request in the making: seasons, options, submit. Owned here so it survives the sheet being
    /// opened and closed again, and so the page can read `didSubmit` for its post-request CTA.
    @State private var draft: SeerrRequestDraft
    /// Withdrawing an existing request is the page's own action, not the draft's, and so is its error.
    @State private var showCancelRequestConfirm = false
    @State private var isCancellingRequest = false
    @State private var cancelError: String?

    /// Currently-viewed season; independent of the request set so the user can browse episodes without requesting.
    @State private var viewedSeasonNumber: Int?
    /// Per-season episode cache, lazily populated and kept for the view's lifetime.
    @State private var seasonEpisodes: [Int: [SeerrEpisode]] = [:]
    /// Per-season in-flight markers driving the episode-strip spinner.
    @State private var loadingSeasons: Set<Int> = []

    /// Jellyfin ground-truth reconcile of Seerr's cached availability. Seerr's mediaInfo.status stays "available" after a Radarr/Sonarr deletion until its ~6h availability-sync runs; Sodalite is the Jellyfin client, so it cross-checks the library directly and overrides stale "available" with .deleted. .unknown = trust Seerr (no Jellyfin user, lookup failed, or Seerr never claimed availability).
    @State private var titlePresence: JellyfinPresence = .unknown
    /// Per-season episode-file presence in Jellyfin (seasonNumber -> hasFiles); nil until the reconcile runs for a present series. A Seerr-available season absent here (or false) was deleted server-side.
    @State private var jellyfinSeasonHasFiles: [Int: Bool]?

    /// Recommendations (falling back to similar), loaded in parallel with the detail so the screen paints first.
    @State private var recommendations: [SeerrMedia] = []
    /// Rotten Tomatoes critics score, best-effort from Seerr's ratings endpoint; nil on older server / no RT data.
    @State private var rtCriticsScore: Int?
    @State private var navigateToMedia: SeerrMedia?
    @State private var selectedCastMember: CastMember?
    /// TMDB collection this movie belongs to; nil for standalone movies and for every series (Sodalite#52).
    @State private var navigateToCollection: SeerrCollectionRef?

    /// The request sheet: seasons, options and the confirm, all in one panel (Sodalite#132).
    @State private var showRequestSheet = false

    /// First-screen focus. Seeded to `.request` once loaded so no focus lands below the fold and triggers an on-open auto-scroll (old tab-bar-stuck-hidden bug).
    @FocusState private var focusedField: DetailFocus?
    /// Overview box below the fold holds focus: Withdraw request leaves the focus engine for that
    /// time so an up-move can only land on the request button (Sodalite#53 follow-up).
    @State private var overviewHasFocus = false
    private enum DetailFocus: Hashable { case request }

    init(media: SeerrMedia) {
        self.media = media
        _draft = State(initialValue: SeerrRequestDraft(mediaType: media.mediaType, tmdbID: media.id))
    }

    /// Result of the Jellyfin library cross-check. .unknown degrades to trusting Seerr; never a false .absent.
    private enum JellyfinPresence: Equatable { case unknown, present, absent }

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            DetailBackdrop(
                imageURL: SeerrImageURL.backdrop(path: backdropPath),
                posterFallbackURL: SeerrImageURL.poster(path: posterPath, size: .w780)
            )
                .id(backdropPath ?? "empty")
                .ignoresSafeArea()

            content
        }
        .ignoresSafeArea(when: !isPhonePortrait)
        .hidesToolbarBackground()
        .hidesShellTabBar()
        .navigationDestination(item: $navigateToMedia) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .navigationDestination(item: $selectedCastMember) { member in
            PersonDetailView(personID: member.personID, personName: member.name)
                .detailCoverPush()
        }
        .navigationDestination(item: $navigateToCollection) { collection in
            // Hand over the Radarr options this screen already resolved: re-deriving them there is two more round
            // trips against a live Radarr, and the request button is the first focused element on that page, so its
            // sheet regularly opened before they landed and silently offered no options at all.
            CatalogCollectionView(
                collection: collection,
                serviceDetails: draft.options.details,
                profileID: draft.options.profileID,
                rootFolder: draft.options.rootFolder,
                implicitOptions: draft.options.implicit
            )
                .detailCoverPush()
        }
        .menuPresentation(isPresented: $showRequestSheet, panel: .plain) {
            SeerrRequestSheet(
                draft: draft,
                title: displayTitle,
                subtitle: displayYear,
                status: { seasonStatus(number: $0) },
                onSubmitted: {
                    showRequestSheet = false
                    // My Requests / the admin queue hold their rows until told; without this the new request
                    // sits invisible in those lists until an app restart.
                    NotificationCenter.default.post(name: .seerrRequestsDidChange, object: nil)
                    Task { await refreshDetailAfterRequest() }
                },
                onCancel: { showRequestSheet = false }
            )
        }
        .onChange(of: isLoading) { _, loading in
            // Focus the action button so nothing below the fold auto-scrolls; defer dodges the focus-commit race (as MovieDetailView).
            if loading == false {
                deferOnMain(by: 0.1) { focusedField = .request }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            errorState(message: errorMessage)
        } else {
            // Same shape as MovieDetailView: hero + bottom-aligned primary block fill screen one, rest scrolls below the fold; default focus stays in the visible block so opening never auto-scrolls (left the tab bar stuck hidden on mid-scroll back-out).
            DetailContentOverlay(
                heroImageURL: SeerrImageURL.backdrop(path: backdropPath),
                heroPosterURL: SeerrImageURL.poster(path: posterPath, size: .w780),
                portraitHero: true,
                hero: {
                heroTitle
            }, primary: {
                primaryBlock
            }) {
                trailingBody
            }
        }
    }

    private func errorState(message: String) -> some View {
        // tvOS Menu pops the nav level only with something focusable; a text-only error screen would exit the app instead. Retry/Back buttons claim focus and give a recovery path.
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: hSizeClass == .compact ? 32 : 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            HStack(spacing: 16) {
                Button {
                    Task { await load() }
                } label: {
                    Text("home.retry")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                .buttonStyle(SettingsTileButtonStyle())
                Button {
                    dismiss()
                } label: {
                    Text("common.back")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .screenContentInset()
    }

    // MARK: - Hero + primary block (first screen)

    @ViewBuilder
    private var heroTitle: some View {
        if isPhonePortrait {
            // On the narrow phone the year + status badge would steal the title's line and squeeze it
            // into a sliver that hard-wraps and truncates. Give the title the full width and drop the
            // year/badge onto their own row beneath it.
            VStack(alignment: .leading, spacing: 8) {
                Text(displayTitle)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)
                heroTitleMeta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(displayTitle)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                heroTitleMeta
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No extra horizontal padding: DetailContentOverlay's hero slot already insets by 50, lining up with the bubble and request button.
    }

    @ViewBuilder
    private var heroTitleMeta: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let year = displayYear {
                Text(year)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let status = mediaStatus, status != .unknown {
                SeerrStatusBadge(status: status)
            }
        }
    }

    private var primaryBlock: some View {
        VStack(alignment: .leading, spacing: 24) {
            metadataBubble
            requestActionRow
        }
        .padding(.horizontal, metrics.rowInset)
    }

    /// Metadata in a frosted bubble (matching Home detail views); left edge at the primary padding (50), aligned with hero title and request button.
    private var metadataBubble: some View {
        VStack(alignment: .leading, spacing: 12) {
            SeerrMetadataRow(
                rating: metadataRating,
                runtimeMinutes: metadataRuntime,
                year: nil,
                certification: metadataCertification,
                rtCriticsScore: rtCriticsScore
            )
            if !genres.isEmpty {
                Text(genres.map(\.name).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    @ViewBuilder
    private var requestActionRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.didSubmit {
                // Post-request CTA: nothing else focusable, so give a back-to-catalog action (else tvOS Menu exits the app).
                GlassActionButton(
                    title: "catalog.request.sent",
                    systemImage: "checkmark.circle.fill",
                    action: { dismiss() }
                )
                .focused($focusedField, equals: .request)
            } else if media.mediaType == .movie || media.mediaType == .tv {
                // Side by side wherever there is width (tvOS, iPad, phone landscape), matching the movie and series
                // detail rows; only the narrow phone portrait stacks them full width.
                if isPhonePortrait {
                    VStack(spacing: 12) { requestButtons }
                } else {
                    HStack(spacing: 16) { requestButtons }
                }

                if let cancelError {
                    Text(cancelError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog(
            "catalog.request.cancel.confirm.title",
            isPresented: $showCancelRequestConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await cancelOpenRequests() }
            } label: {
                Text("catalog.request.cancel.confirm.action")
            }
            Button(role: .cancel) { } label: {
                Text("common.cancel")
            }
        } message: {
            Text("catalog.request.cancel.confirm.message")
        }
    }

    @ViewBuilder
    private var requestButtons: some View {
        GlassActionButton(
            title: "catalog.button.request",
            systemImage: "tray.and.arrow.down",
            isProminent: true,
            action: { openRequestSheet() }
        )
        .focused($focusedField, equals: .request)
        .frame(maxWidth: isPhonePortrait ? .infinity : nil)

        // Only offered while a request is actually open. Jellyseerr never revisits a request once it stops moving (its availability sync looks at available titles only), so a title pulled out of Sonarr elsewhere keeps reporting a pipeline state with no way to clear it from here.
        if !openRequests.isEmpty {
            GlassActionButton(
                title: "catalog.request.cancel",
                systemImage: "xmark.circle",
                isDestructive: true,
                isLoading: isCancellingRequest,
                action: { showCancelRequestConfirm = true }
            )
            .frame(maxWidth: isPhonePortrait ? .infinity : nil)
            .focusSuppressed(overviewHasFocus)
        }
    }

    /// Open requests on the currently loaded detail; drives both the cancel action's visibility and what it deletes.
    private var openRequests: [SeerrRequest] {
        let info = movieDetail?.mediaInfo ?? tvDetail?.mediaInfo
        return (info?.requests ?? []).filter(\.isOpen)
    }

    /// Deletes every open request for this title, then refreshes so the chips drop their pipeline state.
    /// Jellyseerr rejects this with 403 for a user who may not touch the request; that message is surfaced rather than swallowed, since the row stays visible and the user would otherwise retry forever.
    private func cancelOpenRequests() async {
        isCancellingRequest = true
        defer { isCancellingRequest = false }
        cancelError = nil
        do {
            for request in openRequests {
                try await dependencies.seerrRequestService.deleteRequest(requestID: request.id)
            }
            // My Requests / the admin queue hold their rows until told; without this the removed request sits in the list until an app restart.
            NotificationCenter.default.post(name: .seerrRequestsDidChange, object: nil)
            await refreshDetailAfterRequest()
        } catch {
            cancelError = ErrorText.user(for: error)
        }
    }

    /// One button, one meaning: the sheet owns the season selection, the options and the confirm.
    /// It used to scroll the page to the season chips on the first press and submit on the second,
    /// which is what Sodalite#132 reported.
    private func openRequestSheet() {
        if let seasons = availableSeasons, !seasons.isEmpty {
            draft.seed(seasons: seasons, status: { seasonStatus(number: $0) })
        }
        // A failure from a previous attempt is history the moment the sheet is opened again.
        draft.error = nil
        showRequestSheet = true
    }

    // MARK: - Trailing (scrolls below the fold)

    private var trailingBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let overview, !overview.isEmpty {
                // Up out of the box lands on the row's last button, here Withdraw request, unless it
                // is corrected: the engine resolves it from the box's centre (Sodalite#53).
                ExpandableTextBox(
                    text: overview,
                    onFocusMovedUp: { focusedField = .request },
                    onFocusChanged: { overviewHasFocus = $0 }
                )
            }

            // The stub rides along on `/movie/{id}`, so the entry point costs no extra request; the parts are fetched only once the collection is opened.
            if let collection = movieDetail?.collection {
                SeerrCollectionBanner(collection: collection) {
                    navigateToCollection = collection
                }
            }

            if media.mediaType == .tv, let seasons = availableSeasons, !seasons.isEmpty {
                seasonSelection(seasons: seasons)
            }

            if !castMembers.isEmpty {
                MediaCastRow(members: castMembers) { member in
                    if member.personID != nil {
                        selectedCastMember = member
                    }
                }
                .padding(.horizontal, -metrics.rowInset)
            }

            if !regionWatchProviders.isEmpty {
                SeerrWatchProvidersRow(providers: regionWatchProviders)
                    .padding(.horizontal, -metrics.rowInset)
            }

            if !recommendations.isEmpty {
                SeerrHorizontalMediaRow(
                    title: "detail.moreLikeThis",
                    items: recommendations,
                    onItemSelected: { navigateToMedia = $0 }
                )
                .padding(.horizontal, -metrics.rowInset)
            }
        }
        .padding(.horizontal, metrics.rowInset)
    }

    /// Browsing, not requesting: the chips pick which season's episodes to show, and the status badge
    /// says where that season stands. Picking WHAT to request moved into the request sheet, which is
    /// where the confirm button lives (Sodalite#132).
    private func seasonSelection(seasons: [SeerrSeason]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("catalog.seasons.title")
                .font(.title3)
                .fontWeight(.semibold)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(seasons) { season in
                            CatalogSeasonTab(
                                season: season,
                                isViewed: viewedSeasonNumber == season.seasonNumber,
                                availabilityStatus: seasonStatus(season),
                                action: { selectSeasonForViewing(season) }
                            )
                            .id(season.seasonNumber)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .focusSectionCompat()
                .onChange(of: viewedSeasonNumber) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }

            if let viewed = viewedSeasonNumber,
               let season = seasons.first(where: { $0.seasonNumber == viewed }) {
                seasonDetailBlock(season: season)
            }
        }
    }

    @ViewBuilder
    private func seasonDetailBlock(season: SeerrSeason) -> some View {
        let n = season.seasonNumber
        let episodes = seasonEpisodes[n]

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(seasonHeading(season: season))
                    .font(.title3)
                    .fontWeight(.semibold)
                // Informational, and it never gates anything: a season deleted server-side reports stale
                // availability, so every season stays requestable in the sheet whatever this says.
                if let status = seasonStatus(season) {
                    Label(status.seasonLabelKey, systemImage: status.systemImage)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            // Same box as the series overview above: a season synopsis is regularly longer than the
            // three lines a plain Text could show, so it gets the identical focusable / tappable
            // full-text overlay instead of a truncation the user cannot open.
            if let overview = season.overview, !overview.isEmpty {
                ExpandableTextBox(text: overview)
                    .padding(.horizontal, 4)
            }

            if loadingSeasons.contains(n) && (episodes?.isEmpty ?? true) {
                HStack {
                    ProgressView()
                    Spacer()
                }
                // Reserve the height the card row will actually take, so the swap from spinner to cards doesn't jump.
                .frame(height: SeerrEpisodeCard.size(
                    compact: hSizeClass == .compact,
                    cardScale: dependencies.appearancePreferences.cardScale
                ).height + (hSizeClass == .compact ? 58 : 40))
                .padding(.horizontal, 20)
            } else if let episodes, !episodes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: hSizeClass == .compact ? metrics.itemSpacing : 24) {
                        ForEach(episodes) { ep in
                            FocusableCard(action: {}) { focused in
                                SeerrEpisodeCard(episode: ep, isFocused: focused)
                            }
                            .id("\(n)-\(ep.episodeNumber)")
                        }
                    }
                    .padding(.horizontal, 20)
                    // Room for the focused card's scale (1.04) + drop shadow (radius 14, y 6) the ScrollView would otherwise clip.
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .focusSectionCompat()
            } else if !loadingSeasons.contains(n) {
                Text("catalog.seasons.noEpisodes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 4)
    }

    private func seasonHeading(season: SeerrSeason) -> String {
        let label = String(localized: "catalog.season", defaultValue: "Season")
        if let name = season.name, !name.isEmpty, name != "\(label) \(season.seasonNumber)" {
            return "\(label) \(season.seasonNumber) · \(name)"
        }
        return "\(label) \(season.seasonNumber)"
    }

    private func selectSeasonForViewing(_ season: SeerrSeason) {
        let n = season.seasonNumber
        viewedSeasonNumber = n
        guard seasonEpisodes[n] == nil, !loadingSeasons.contains(n) else { return }
        Task { await loadSeasonEpisodes(seasonNumber: n) }
    }

    private func loadSeasonEpisodes(seasonNumber: Int) async {
        guard let tvID = tvDetail?.id else { return }
        loadingSeasons.insert(seasonNumber)
        defer { loadingSeasons.remove(seasonNumber) }
        do {
            let detail = try await dependencies.seerrMediaService.tvSeasonDetail(
                tmdbID: tvID,
                seasonNumber: seasonNumber
            )
            seasonEpisodes[seasonNumber] = detail.episodes ?? []
        } catch {
            // Best-effort: leave the cache empty so "no episodes" renders; a banner would compete with the request-error label.
        }
    }

    // MARK: - Derived

    private var displayTitle: String {
        movieDetail?.title ?? tvDetail?.name ?? media.displayTitle
    }

    private var displayYear: String? {
        movieDetail?.displayYear ?? tvDetail?.displayYear ?? media.displayYear
    }

    private var overview: String? {
        movieDetail?.overview ?? tvDetail?.overview ?? media.overview
    }

    private var genres: [SeerrGenre] {
        movieDetail?.genres ?? tvDetail?.genres ?? []
    }

    private var backdropPath: String? {
        movieDetail?.backdropPath ?? tvDetail?.backdropPath ?? media.backdropPath
    }

    /// Same fetched-first order as `backdropPath`. Reading it off `media` alone left the hero blank for the whole visit when the screen was entered from My Requests, which navigates with a bare tmdb-id stub: the phone-portrait hero shows the poster ONLY, so the stub's nil poster was the entire hero.
    private var posterPath: String? {
        movieDetail?.posterPath ?? tvDetail?.posterPath ?? media.posterPath
    }

    private var mediaStatus: SeerrMediaStatus? {
        let seerr = movieDetail?.mediaInfo?.status ?? tvDetail?.mediaInfo?.status ?? media.mediaInfo?.status
        // Jellyfin ground truth: the whole title is gone, so override Seerr's stale "available" badge with .deleted.
        if (seerr == .available || seerr == .partiallyAvailable), titlePresence == .absent {
            return .deleted
        }
        return seerr
    }

    private var availableSeasons: [SeerrSeason]? {
        tvDetail?.seasons?.filter { $0.seasonNumber > 0 }
    }

    private var deviceRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    private var metadataRating: Double? {
        movieDetail?.voteAverage ?? tvDetail?.voteAverage ?? media.voteAverage
    }

    /// Runtime in minutes. Movies only; TV omits it in SP1.
    private var metadataRuntime: Int? {
        movieDetail?.runtime
    }

    private var metadataCertification: String? {
        movieDetail?.certification(region: deviceRegion)
            ?? tvDetail?.certification(region: deviceRegion)
    }

    private var castMembers: [CastMember] {
        let cast = movieDetail?.credits?.cast ?? tvDetail?.credits?.cast ?? []
        return cast.prefix(15).map { member in
            CastMember(
                id: "\(member.id)",
                name: member.name,
                role: member.character,
                imageURL: SeerrImageURL.profile(
                    path: member.profilePath,
                    size: .covering(metrics.castImageWidth)
                ),
                personID: member.id,
                jellyfinPersonID: nil
            )
        }
    }

    /// Flatrate providers for the device region, falling back to US then the first region; empty when none.
    private var regionWatchProviders: [SeerrWatchProvider] {
        let regions = movieDetail?.watchProviders ?? tvDetail?.watchProviders ?? []
        guard !regions.isEmpty else { return [] }
        let pick = regions.first { $0.iso31661 == deviceRegion }
            ?? regions.first { $0.iso31661 == "US" }
            ?? regions.first
        return pick?.flatrate ?? []
    }

    /// Informational status for the season, or nil if untracked. Never gates requesting (status is display-only); a deleted/declined season must still be re-requestable.
    /// Layers Seerr's cached status with the Jellyfin ground-truth override: a stale "available" is downgraded to .deleted when the season's episode files are actually gone from the library.
    private func seasonStatus(_ season: SeerrSeason) -> SeerrMediaStatus? {
        seasonStatus(number: season.seasonNumber)
    }

    /// By number, because the request sheet asks that way: it holds season numbers, not the models.
    private func seasonStatus(number n: Int) -> SeerrMediaStatus? {
        let seerr = SeerrSeasonStatusResolver.status(seasonNumber: n, mediaInfo: tvDetail?.mediaInfo)
        // Jellyfin ground truth: override Seerr's stale available/partially-available with .deleted when the show is gone entirely (titlePresence absent) or this specific season has no episode files, so the user sees it's gone (and can re-request).
        if seerr == .available || seerr == .partiallyAvailable {
            if titlePresence == .absent { return .deleted }
            if let hasFiles = jellyfinSeasonHasFiles, hasFiles[n] != true {
                return .deleted
            }
        }
        return seerr
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Fire-and-forget (not async let): detail render must not block on best-effort Radarr/Sonarr config that only feeds optional dropdowns.
        Task {
            await draft.options.load(
                service: dependencies.seerrServiceConfigService,
                mediaType: media.mediaType
            )
        }
        Task { await loadRecommendations() }
        Task { await loadRatings() }

        do {
            switch media.mediaType {
            case .movie:
                movieDetail = try await dependencies.seerrMediaService.movieDetail(tmdbID: media.id)
                // Background: reconcile Seerr's cached availability against the Jellyfin library; patches the badge after first paint, never blocks.
                Task { await reconcileAvailability() }
                return
            case .tv:
                let detail = try await dependencies.seerrMediaService.tvDetail(tmdbID: media.id)
                tvDetail = detail
                Task { await reconcileAvailability() }
                // Default to the lowest real season (skip specials/season 0) synchronously so the episode block has content the instant loading ends.
                let realSeasons = (detail.seasons ?? [])
                    .filter { $0.seasonNumber > 0 }
                    .map(\.seasonNumber)
                    .sorted()
                if let first = realSeasons.first {
                    viewedSeasonNumber = first
                    // Strictly lazy (one season up front). Fanning out one tvSeasonDetail per season fired 30+ parallel HTTP/2 streams at remote Jellyseerr, saturating the pool and starving TMDB artwork loads.
                    Task { await loadSeasonEpisodes(seasonNumber: first) }
                }
                return
            case .person, .unknown:
                return
            }
        } catch {
            errorMessage = ErrorText.user(for: error)
        }
    }

    /// Cross-checks Seerr's cached availability against the Jellyfin library (the playability ground truth). Runs only when Seerr claims available/partially-available; degrades to .unknown (trust Seerr) on any lookup failure, never a false "deleted". For series it also builds the per-season episode-file map so individually deleted seasons surface even when the show is otherwise present.
    private func reconcileAvailability() async {
        guard let userID = appState.activeUser?.id else { return }
        let seerrStatus = movieDetail?.mediaInfo?.status ?? tvDetail?.mediaInfo?.status
        guard seerrStatus == .available || seerrStatus == .partiallyAvailable else { return }

        let service = dependencies.jellyfinItemService
        switch media.mediaType {
        case .movie:
            do {
                let item: JellyfinItem
                switch try await resolveLibraryItem(userID: userID, types: [.movie]) {
                case .found(let found): item = found
                case .gone:
                    titlePresence = .absent
                    return
                case .unresolved:
                    // Not proven gone: leave Seerr's own status standing.
                    titlePresence = .unknown
                    return
                }
                // Present only if the matched item carries a real media source; a shell with no file counts as gone.
                titlePresence = (item.mediaSources?.isEmpty == false) ? .present : .absent
            } catch {
                titlePresence = .unknown
            }
        case .tv:
            do {
                let series: JellyfinItem
                switch try await resolveLibraryItem(userID: userID, types: [.series]) {
                case .found(let found): series = found
                case .gone:
                    titlePresence = .absent
                    return
                case .unresolved:
                    titlePresence = .unknown
                    return
                }
                titlePresence = .present
                // childCount rides on the seasons endpoint's ChildCount field (seasonListFields, and it has to be that exact field); a season Jellyfin lists with zero episode files, or doesn't list at all, was deleted.
                let seasons = try await service.getSeasons(seriesID: series.id, userID: userID).items
                var hasFiles: [Int: Bool] = [:]
                for season in seasons {
                    guard let n = season.indexNumber else { continue }
                    hasFiles[n] = (season.childCount ?? 0) > 0
                }
                jellyfinSeasonHasFiles = hasFiles
            } catch {
                titlePresence = .unknown
            }
        case .person, .unknown:
            break
        }
    }

    private enum LibraryLookup {
        case found(JellyfinItem)
        /// Proven deleted.
        case gone
        /// Not found, which is not the same as gone.
        case unresolved
    }

    /// Jellyseerr's own `jellyfinMediaId` first: it is an exact link, written by the scan that decided this title is available. A 404 on it is real proof the item is gone, which no provider-id guess can give, but only for a user who could see it (`seesWholeLibrary`): a restricted profile gets the same 404 for an item outside its reach.
    /// Only when Seerr carries no link (Overseerr, or an unmatched title) does it fall back to the id-verified title search.
    private func resolveLibraryItem(userID: String, types: [ItemType]) async throws -> LibraryLookup {
        let service = dependencies.jellyfinItemService
        let info = movieDetail?.mediaInfo ?? tvDetail?.mediaInfo
        if let linkedID = info?.jellyfinMediaId, !linkedID.isEmpty {
            do {
                return .found(try await service.getItemDetail(userID: userID, itemID: linkedID))
            } catch let error as APIError where error.isNotFound {
                return appState.activeUser?.seesWholeLibrary == true ? .gone : .unresolved
            }
        }
        let match = try await service.findByProviderIDs(
            userID: userID,
            tmdbID: media.id,
            tvdbID: tvDetail?.externalIds?.tvdbId,
            imdbID: tvDetail?.externalIds?.imdbId ?? movieDetail?.externalIds?.imdbId,
            includeItemTypes: types,
            searchTerm: tvDetail?.name ?? movieDetail?.title ?? media.displayTitle
        )
        return match.map(LibraryLookup.found) ?? .unresolved
    }

    private func loadRecommendations() async {
        let service = dependencies.seerrMediaService
        do {
            // Titles the server already has are dropped: this row is the catalog, and what is on the
            // server belongs on its own detail page, not behind a request button (Vincent, 2026-08-17).
            // The filter runs before the empty check, so a wall of owned recommendations falls through
            // to similar instead of leaving the row looking short for no reason.
            let recs = SeerrLibraryDedupe.droppingAvailable(
                try await service.recommendations(mediaType: media.mediaType, tmdbID: media.id)
            )
            if !recs.isEmpty {
                recommendations = recs
                return
            }
            recommendations = SeerrLibraryDedupe.droppingAvailable(
                try await service.similar(mediaType: media.mediaType, tmdbID: media.id)
            )
        } catch {
            // Best-effort: leave the row absent, no banner.
        }
    }

    private func loadRatings() async {
        // Nothing to draw, nothing to ask for (Sodalite#127).
        guard dependencies.appearancePreferences.showCriticRating else { return }
        // Best-effort: the ratings endpoint 404s on older servers or when no
        // RT data exists, leave the badge absent in that case.
        guard let rt = try? await dependencies.seerrMediaService.ratings(
            mediaType: media.mediaType, tmdbID: media.id
        ) else { return }
        if let score = rt.criticsScore { rtCriticsScore = score }
    }

    /// Light refresh after a successful request: replaces only the mediaInfo-carrying detail (badges/chips pick up pending state); tab selection and episode lists stay untouched. NOT load(): that flips the full-screen loading state and re-runs config/recommendations.
    private func refreshDetailAfterRequest() async {
        do {
            switch media.mediaType {
            case .movie:
                movieDetail = try await dependencies.seerrMediaService.movieDetail(tmdbID: media.id)
            case .tv:
                tvDetail = try await dependencies.seerrMediaService.tvDetail(tmdbID: media.id)
            case .person, .unknown:
                break
            }
            // Re-reconcile so the Jellyfin presence verdict matches the refreshed mediaInfo; background so it doesn't extend the submit spinner, self-guards on Seerr still claiming availability.
            Task { await reconcileAvailability() }
        } catch {
            // Badges stay stale until the next open; not worth an alert.
        }
    }
}
