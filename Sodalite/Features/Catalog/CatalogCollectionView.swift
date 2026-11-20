import SwiftUI

/// Seerr collection page (Sodalite#52): all parts of a TMDB movie collection with their availability, plus a bulk
/// request for the ones the library is missing. Entered from a Catalog movie detail whose `/movie/{id}` payload
/// carried a `collection` stub, so the parts are fetched only when the page is actually opened.
struct CatalogCollectionView: View {
    let collection: SeerrCollectionRef

    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    @State private var detail: SeerrCollection?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedMedia: SeerrMedia?

    /// Radarr defaults for the bulk request, seeded from the pushing movie detail so the options are on screen from
    /// the first frame; only a cold entry has to resolve them here.
    @State private var options: SeerrRequestOptions

    @State private var showRequestOptions = false
    @State private var isSubmitting = false
    @State private var requestError: String?
    @State private var bulkResult: BulkRequestResult?

    /// First-screen focus, seeded onto the action button so nothing below the fold claims it and auto-scrolls the page on open.
    @FocusState private var focusedField: Focus?
    private enum Focus: Hashable { case action }

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    /// Adaptive on every tier, the same definition the filmography and the catalog grid use: five
    /// fixed 220pt columns left a third of a 4K row empty and needed a width cap to stay left-bound,
    /// adaptive fills the row on its own and still wraps to what an iPad in portrait fits (Sodalite#57).
    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: metrics.gridColumnMinimum(
                cardScale: dependencies.appearancePreferences.cardScale)),
            spacing: metrics.gridSpacing
        )]
    }

    init(
        collection: SeerrCollectionRef,
        serviceDetails: SeerrServiceDetails? = nil,
        profileID: Int? = nil,
        rootFolder: String? = nil,
        implicitOptions: SeerrRequestDefaults.Implicit? = nil
    ) {
        self.collection = collection
        _options = State(initialValue: SeerrRequestOptions(
            details: serviceDetails,
            profileID: profileID,
            rootFolder: rootFolder,
            implicit: implicitOptions
        ))
    }

    var body: some View {
        ZStack {
            DetailBackdrop(
                imageURL: SeerrImageURL.backdrop(path: detail?.backdropPath ?? collection.backdropPath),
                posterFallbackURL: SeerrImageURL.poster(path: detail?.posterPath ?? collection.posterPath, size: .w780)
            )
            .ignoresSafeArea()

            content
        }
        .ignoresSafeArea(when: !isPhonePortrait)
        .hidesToolbarBackground()
        .hidesShellTabBar()
        .navigationDestination(item: $selectedMedia) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .menuPresentation(isPresented: $showRequestOptions) {
            requestOptionsSheet
        }
        .onChange(of: isLoading) { _, loading in
            // Defer dodges the focus-commit race, same as the movie detail.
            if loading == false {
                deferOnMain(by: 0.1) { focusedField = .action }
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
            DetailContentOverlay(
                heroImageURL: SeerrImageURL.backdrop(path: detail?.backdropPath ?? collection.backdropPath),
                heroPosterURL: SeerrImageURL.poster(path: detail?.posterPath ?? collection.posterPath, size: .w780),
                heroTallImageURL: SeerrImageURL.backdrop(path: detail?.backdropPath ?? collection.backdropPath, size: .original),
                portraitHero: true,
                primary: {
                VStack(alignment: .leading, spacing: 24) {
                    glassPanel
                    actionBlock
                }
                .padding(.horizontal, metrics.rowInset)
            }) {
                if let overview = detail?.overview, !overview.isEmpty {
                    // No correction needed here, unlike the other detail pages: the action block holds
                    // exactly one focusable button, so an up-move has nowhere else to land (Sodalite#53).
                    ExpandableTextBox(text: overview)
                        .padding(.horizontal, metrics.rowInset)
                }

                partsGrid
            }
        }
    }

    private var glassPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detail?.name ?? collection.name)
                .font(.largeTitle)
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)

            if !parts.isEmpty {
                Text("detail.collection.itemCount \(parts.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// One focusable button in every state, so a Menu press on the first screen pops back instead of exiting the app
    /// and the seeded focus never lands in the grid below the fold. Deliberately not an if/else over two buttons: the
    /// bulk request empties `missingParts` while the sheet is closing, and swapping the view identity underneath
    /// would drop focus into the grid and auto-scroll the page.
    private var actionBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassActionButton(
                title: actionTitle,
                systemImage: hasMissingParts ? "tray.and.arrow.down" : "checkmark.circle.fill",
                isProminent: hasMissingParts,
                isLoading: isSubmitting,
                action: {
                    if hasMissingParts {
                        showRequestOptions = true
                    } else {
                        dismiss()
                    }
                }
            )
            .focused($focusedField, equals: .action)
            .frame(maxWidth: isPhonePortrait ? .infinity : nil)

            if let bulkResult {
                Text("catalog.collection.requestResult \(bulkResult.requested) \(bulkResult.attempted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let requestError {
                Text(requestError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var partsGrid: some View {
        if parts.isEmpty {
            Text("catalog.collection.empty")
                .foregroundStyle(.secondary)
                .padding(.horizontal, metrics.rowInset)
        } else {
            // .leading so a short last row keeps the left edge of the rows above it.
            LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                // stableKey, not Identifiable's id: the grid shape is shared with mixed movie/tv grids where TMDB ids collide.
                ForEach(parts, id: \.stableKey) { part in
                    FocusableCard {
                        selectedMedia = part
                    } content: { focused in
                        SeerrMediaCard(media: part, isFocused: focused)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.rowInset)
        }
    }

    // MARK: - Request options sheet

    // No ScrollView wrapper: a ScrollView root under-reports its height to a tvOS sheet and clips the focused confirm button's halo.
    private var requestOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(detail?.name ?? collection.name)
                .font(.title2)
                .fontWeight(.bold)

            Text("catalog.collection.requestMissing.explain \(missingParts.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // The form itself renders the "still resolving" line: an empty section reads as "this server
            // has none" while the Radarr lookup is in flight.
            SeerrRequestOptionsForm(options: options)

            // Always closes: the outcome (count plus the first failure) is rendered on the page behind, so a partial
            // result is not stranded inside a sheet the user then has to dismiss to act on.
            Button {
                Task {
                    await submitMissing()
                    showRequestOptions = false
                }
            } label: {
                if isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    Label("catalog.collection.requestMissing", systemImage: "tray.and.arrow.down")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .buttonStyle(SettingsTileButtonStyle())
            .disabled(isSubmitting || missingParts.isEmpty)
        }
        .padding(48)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func errorState(message: String) -> some View {
        // tvOS Menu pops the nav level only with something focusable; a text-only error screen would exit the app instead.
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

    // MARK: - Derived

    private var parts: [SeerrMedia] {
        detail?.parts ?? []
    }

    private var missingParts: [SeerrMedia] {
        SeerrCollectionRequestPlan.missingParts(in: parts)
    }

    private var hasMissingParts: Bool { !missingParts.isEmpty }

    private var actionTitle: LocalizedStringKey {
        if hasMissingParts { return "catalog.collection.requestMissing" }
        return bulkResult == nil ? "catalog.collection.allPresent" : "catalog.collection.requested"
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Fire-and-forget: the grid must not wait on best-effort Radarr config that only feeds optional dropdowns.
        Task {
            await options.load(service: dependencies.seerrServiceConfigService, mediaType: .movie)
        }

        do {
            detail = try await dependencies.seerrMediaService.collection(collectionID: collection.id)
        } catch {
            errorMessage = ErrorText.user(for: error)
        }
    }

    /// Requests every missing part in turn. Jellyseerr has no bulk endpoint, its own collection page posts one request
    /// per movie too. Sequential rather than fanned out: a collection is a handful of titles, and a burst of parallel
    /// POSTs against a remote instance buys nothing but a contended request pool.
    private func submitMissing() async {
        guard !isSubmitting else { return }
        let targets = missingParts
        guard !targets.isEmpty else { return }

        isSubmitting = true
        requestError = nil
        defer { isSubmitting = false }

        var requested = 0
        var firstFailure: String?

        for part in targets {
            do {
                _ = try await dependencies.seerrRequestService.createRequest(
                    mediaType: .movie,
                    tmdbID: part.id,
                    seasons: nil,
                    serverID: options.serverIDPayload,
                    profileID: options.profileIDPayload,
                    rootFolder: options.rootFolderPayload,
                    languageProfileID: nil,
                    tags: options.tagsPayload
                )
                requested += 1
            } catch SeerrRequestError.noSeasonsAvailable {
                // 202: this title turned out to be requested or available after all. Not an error, just nothing to do.
                continue
            } catch {
                // Keep going: one title Radarr cannot take (very new releases are a common case) must not strand the rest.
                if firstFailure == nil { firstFailure = ErrorText.user(for: error) }
            }
        }

        bulkResult = BulkRequestResult(requested: requested, attempted: targets.count)
        requestError = firstFailure

        if requested > 0 {
            // My Requests / the admin queue hold their rows until told.
            NotificationCenter.default.post(name: .seerrRequestsDidChange, object: nil)
        }
        await refreshAfterRequest()
    }

    /// Re-fetches the collection so the part badges pick up their new pending state.
    private func refreshAfterRequest() async {
        guard let refreshed = try? await dependencies.seerrMediaService.collection(
            collectionID: collection.id
        ) else { return }
        detail = refreshed
    }

    private struct BulkRequestResult {
        let requested: Int
        let attempted: Int
    }
}

/// Entry point on a Catalog movie detail: backdrop strip carrying the collection name.
struct SeerrCollectionBanner: View {
    let collection: SeerrCollectionRef
    let action: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var bannerHeight: CGFloat {
        hSizeClass == .compact ? 120 : 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("catalog.collection.partOf")
                .font(.title3)
                .fontWeight(.semibold)

            FocusableCard(action: action) { focused in
                ZStack(alignment: .bottomLeading) {
                    AsyncCachedImage(url: SeerrImageURL.backdrop(path: collection.backdropPath)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.Theme.surface)
                    }
                    .frame(height: bannerHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.5), .black.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text("catalog.collection.view")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(hSizeClass == .compact ? 12 : 20)
                }
                .frame(height: bannerHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
                .overlay(
                    MediaFocusRing(
                        cornerRadius: ArtworkCorner.radius,
                        isFocused: focused
                    )
                )
            }
        }
    }
}
