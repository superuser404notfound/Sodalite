import SwiftUI

struct SearchView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    /// The edge the section headings and their rows share with every other tab (Sodalite#140).
    private var leadingInset: CGFloat { metrics.rowLeading(shellPaysLeading: shellPaysLeading) }
    @State private var viewModel: SearchViewModel?
    @State private var destination: Destination?
    /// Drives the iOS bar's Cancel button: the keyboard covers the tab bar, so without it Return was
    /// the only way out of the field (Sodalite#208).
    @State private var isSearchFieldEditing = false

    private var seerrBrowsingEnabled: Bool {
        SeerrSurfacePolicy.browsingEnabled(
            appState: appState,
            appearance: dependencies.appearancePreferences
        )
    }

    /// One cover for all three result kinds. Stacking a `fullScreenCover` per kind is the shape
    /// where only the last one attached ever presents, and the older path dies without a warning.
    private enum Destination: Identifiable {
        case library(JellyfinItem)
        /// A result's Play: its detail page, straight into the player.
        case play(JellyfinItem, fromBeginning: Bool)
        case catalog(SeerrMedia)
        case person(PersonRoute)

        var id: String {
            switch self {
            case .library(let item): "library-\(item.id)"
            case .play(let item, let fromBeginning): "play-\(item.id)-\(fromBeginning)"
            case .catalog(let media): "catalog-\(media.stableKey)"
            case .person(let route): "person-\(route.id)"
            }
        }
    }

    var body: some View {
        ThemeNavigationStack {
            VStack(spacing: 0) {
                #if os(tvOS)
                if let vm = viewModel {
                    InlineSearchContainer(
                        text: Bindable(vm).query,
                        placeholder: String(localized: "search.placeholder", defaultValue: "Search")
                    ) {
                        resultsArea(vm: vm)
                    }
                    .onChange(of: vm.query) { _, _ in
                        vm.scheduleSearch()
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #else
                searchBar

                if let vm = viewModel {
                    resultsArea(vm: vm)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #endif
            }
            .reservesShellChrome()
            // Below the cover, so a detail page's own rows do not ask this host for a second one.
            .environment(\.playMediaItem, PlayMediaItemAction { item, fromBeginning in
                destination = .play(item, fromBeginning: fromBeginning)
            })
            // Full-screen cover (over the tab bar) instead of a push: the bar is never hidden/removed, so it is never re-templated gray on return (tvOS 26). See detailCover.
            .detailCover(item: $destination) { destination in
                switch destination {
                case .library(let item):
                    DetailRouterView(item: item)
                case .play(let item, let fromBeginning):
                    DetailRouterView(item: item, autoPlay: true, autoPlayFromBeginning: fromBeginning)
                case .catalog(let media):
                    CatalogDetailView(media: media)
                case .person(let route):
                    PersonDetailView(
                        personID: route.tmdbID,
                        jellyfinPersonID: route.jellyfinPersonID,
                        personName: route.name
                    )
                }
            }
        }
        .onAppear(perform: bootstrap)
        #if os(iOS)
        .onChange(of: appState.requestSearchFieldFocus) { _, _ in
            isSearchFieldEditing = true
        }
        #endif
        // Who takes part changed (Combine servers, a server muted or back): the next search uses it (Sodalite#85).
        .onChange(of: dependencies.sessionRegistry.participantsRevision) { _, _ in
            guard let vm = viewModel, let userID = appState.activeUser?.id else { return }
            vm.sources = dependencies.searchSources(activeUserID: userID)
        }
        // Reactive Seerr hookup: bootstrap captures the flag once, so hitting Search before restoreSession finishes the Seerr part would pin a nil service for the session. Re-sync on change keeps the catalog half live, and it follows the Catalog tab's visibility too (Sodalite#62).
        .onChange(of: seerrBrowsingEnabled) { _, enabled in
            viewModel?.seerrSearchService = enabled ? dependencies.seerrSearchService : nil
            // Re-run the active query so the Seerr half catches up without retyping.
            viewModel?.scheduleSearch()
        }
        .onChange(of: appState.activeUser?.id) { _, newValue in
            // Profile switch: drop the VM so .onAppear rebuilds for the new user (mirrors HomeView); keeping it pins the old userID into /Users/{id}/Items searches, 403ing the new token.
            viewModel = nil
            guard newValue != nil else { return }
            bootstrap()
        }
        // Pre-warm the poster cache on results-change so first focus doesn't pay round-trip + decode. Bounded-concurrency prefetch so it doesn't starve foreground bandwidth.
        .onChange(of: viewModel?.jellyfinResults) { _, _ in
            prefetchSearchPosters()
        }
        .onChange(of: viewModel?.seerrResults) { _, _ in
            prefetchSearchPosters()
        }
        .onChange(of: viewModel?.peopleResults) { _, _ in
            prefetchSearchPosters()
        }
    }

    /// Hand current result poster URLs to `ImageCache.prefetch`; cached URLs are skipped, so only new posters pay network on each results-change.
    private func prefetchSearchPosters() {
        guard let vm = viewModel else { return }
        var urls: [URL] = []
        for item in vm.jellyfinResults {
            if let url = dependencies.jellyfinImageService.posterURL(for: item) {
                urls.append(url)
            }
        }
        for media in vm.seerrResults {
            if let url = SeerrImageURL.poster(
                path: media.posterPath, size: .covering(ImageWidth.card)
            ) {
                urls.append(url)
            }
        }
        for person in vm.peopleResults {
            if let url = SeerrImageURL.profile(
                path: person.profilePath,
                size: .covering(metrics.castImageWidth)
            ) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        let auth = ImageAuth.snapshot(dependencies.sessionRegistry)
        Task.detached(priority: .utility) {
            await ImageCache.prefetch(urls, auth: auth)
        }
    }

    #if !os(tvOS)
    /// Inline UIKit UITextField bar for iOS. tvOS uses InlineSearchContainer, so its results stay
    /// visible while typing.
    @ViewBuilder
    private var searchBar: some View {
        if let vm = viewModel {
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    searchField(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: 42)
                        .onChange(of: vm.query) { _, _ in
                            vm.scheduleSearch()
                        }

                    if vm.isSearching {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.Theme.restFill)
                )

                #if os(iOS)
                if isSearchFieldEditing {
                    // Only drops the keyboard: the field's own clear button already empties the query.
                    Button("common.cancel") {
                        isSearchFieldEditing = false
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                #endif
            }
            .animation(.snappy, value: isSearchFieldEditing)
            .padding(.leading, metrics.screenLeading(shellPaysLeading: shellPaysLeading))
            .padding(.trailing, metrics.screenHInset)
            .padding(.top, 38)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private func searchField(vm: SearchViewModel) -> some View {
        let placeholder = String(localized: "search.placeholder", defaultValue: "Search")
        #if os(iOS)
        SearchTextField(text: Bindable(vm).query, isEditing: $isSearchFieldEditing, placeholder: placeholder)
        #else
        SearchTextField(text: Bindable(vm).query, placeholder: placeholder)
        #endif
    }
    #endif

    @ViewBuilder
    private func resultsArea(vm: SearchViewModel) -> some View {
        if vm.jellyfinResults.isEmpty && vm.seerrResults.isEmpty && vm.peopleResults.isEmpty {
            emptyState(vm: vm)
        } else {
            resultsView(vm: vm)
        }
    }

    @ViewBuilder
    private func resultsView(vm: SearchViewModel) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if !vm.jellyfinResults.isEmpty {
                    librarySection(items: vm.jellyfinResults)
                }
                // People sit between the two title rows: what the library already owns stays on top,
                // and the person leads into the catalog titles they belong to.
                if !vm.peopleResults.isEmpty {
                    peopleSection(people: vm.peopleResults)
                }
                if !vm.seerrResults.isEmpty {
                    catalogSection(items: vm.seerrResults)
                }
                if vm.isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 20)
        }
        // Scrolling the hits is the other way out of the keyboard, and it keeps the query.
        .scrollDismissesKeyboard(.immediately)
        .drivesShellBar()
    }

    private func librarySection(items: [JellyfinItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "house.fill", title: "search.section.library", tint: .accentColor)
                .padding(.leading, leadingInset)
                .padding(.trailing, 50)

            RowScrollView(leading: leadingInset, trailing: 50, vertical: 20) {
                LazyHStack(spacing: 30) {
                    ForEach(items) { item in
                        FocusableCard(opensMenuOnHold: true) {
                            destination = .library(item)
                        } content: { isFocused in
                            MediaCard(
                                item: item,
                                imageURL: dependencies.jellyfinImageService.imageURL(
                                    itemID: item.id,
                                    serverID: item.serverID,
                                    imageType: .primary,
                                    tag: item.imageTags?.primary,
                                    maxWidth: ImageWidth.card
                                ),
                                style: .poster,
                                isFocused: isFocused
                            )
                        }
                        .mediaContextMenu(for: item) { destination = .library($0) }
                    }
                }
                .enrichesPosterBadges(items)
            }
            // .focusSection() so vertical nav crosses row boundaries when geometry doesn't line up (right-side catalog card over a one-item library row); else up-press finds nothing overhead and dies.
            .focusSectionCompat()
        }
    }

    /// Reuses the cast strip, so the portraits, focus ring and tier sizing are the ones the detail
    /// pages already ship; only the heading is drawn here to match the neighbouring sections.
    private func peopleSection(people: [SeerrPersonSearchResult]) -> some View {
        let members = people.map { person in
            CastMember(
                id: "person-\(person.id)",
                name: person.name,
                role: person.knownForSummary,
                imageURL: SeerrImageURL.profile(
                    path: person.profilePath,
                    size: .covering(metrics.castImageWidth)
                ),
                personID: person.id,
                jellyfinPersonID: nil
            )
        }

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "person.2.fill", title: "search.section.people", tint: .purple)
                .padding(.leading, leadingInset)
                .padding(.trailing, 50)

            MediaCastRow(title: nil, members: members, inset: leadingInset) { member in
                guard let tmdbID = member.personID else { return }
                destination = .person(PersonRoute(tmdbID: tmdbID, name: member.name))
            }
        }
        .focusSectionCompat()
    }

    private func catalogSection(items: [SeerrMedia]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "tray.and.arrow.down", title: "search.section.catalog", tint: .orange)
                .padding(.leading, leadingInset)
                .padding(.trailing, 50)

            RowScrollView(leading: leadingInset, trailing: 50, vertical: 20) {
                LazyHStack(spacing: 30) {
                    // stableKey not id: Seerr's multi-search mixes movies and shows, and the bare
                    // TMDB id collides across the two namespaces (Audit 2026-09-25 BROWSE-8), the
                    // same reason PersonDetailView's filmography row keys on it.
                    ForEach(items, id: \.stableKey) { media in
                        FocusableCard {
                            destination = .catalog(media)
                        } content: { isFocused in
                            SeerrMediaCard(media: media, isFocused: isFocused)
                        }
                    }
                }
            }
            .focusSectionCompat()
        }
    }

    private func sectionHeader(icon: String, title: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private func emptyState(vm: SearchViewModel) -> some View {
        if vm.isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = vm.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.query.trimmingCharacters(in: .whitespaces).count < 2 {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("search.hint.startTyping")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if !appState.isSeerrConnected {
                    Text("search.hint.connectSeerr")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("search.empty.noResults")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bootstrap() {
        guard viewModel == nil, let userID = appState.activeUser?.id else { return }
        viewModel = SearchViewModel(
            itemService: dependencies.jellyfinItemService,
            seerrSearchService: seerrBrowsingEnabled ? dependencies.seerrSearchService : nil,
            userID: userID,
            sources: dependencies.searchSources(activeUserID: userID)
        )
    }
}
