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
    #if os(tvOS)
    @FocusState private var clearFocused: Bool
    #endif

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
        case catalog(SeerrMedia)
        case person(PersonRoute)

        var id: String {
            switch self {
            case .library(let item): "library-\(item.id)"
            case .catalog(let media): "catalog-\(media.stableKey)"
            case .person(let route): "person-\(route.id)"
            }
        }
    }

    var body: some View {
        ThemeNavigationStack {
            VStack(spacing: 0) {
                searchBar

                if let vm = viewModel {
                    if vm.jellyfinResults.isEmpty && vm.seerrResults.isEmpty && vm.peopleResults.isEmpty {
                        emptyState(vm: vm)
                    } else {
                        resultsView(vm: vm)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Full-screen cover (over the tab bar) instead of a push: the bar is never hidden/removed, so it is never re-templated gray on return (tvOS 26). See detailCover.
            .detailCover(item: $destination) { destination in
                switch destination {
                case .library(let item):
                    DetailRouterView(item: item)
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

    /// Inline UIKit UITextField bar: SwiftUI TextField routes focus unreliably on tvOS (silently skipped); .searchable() adds a 1-2s rebuild per tab-switch. UITextField routes reliably with no switch-lag.
    @ViewBuilder
    private var searchBar: some View {
        if let vm = viewModel {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SearchTextField(
                    text: Bindable(vm).query,
                    placeholder: String(localized: "search.placeholder", defaultValue: "Search")
                )
                .frame(maxWidth: .infinity, maxHeight: 42)
                .onChange(of: vm.query) { _, _ in
                    vm.scheduleSearch()
                }

                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                #if os(tvOS)
                // iOS gets UIKit's own clear button inside the field (SearchTextField); tvOS has no
                // pointer to hit it with, so the clear lives beside the field as a focusable target.
                // It stays mounted while focused even after the query empties: dropping the focused
                // view mid-tap hands the focus back to the engine's geometric pick, which lands
                // anywhere but here.
                if !vm.query.isEmpty || clearFocused {
                    clearButton(vm: vm)
                }
                #endif
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.Theme.restFill)
            )
            .padding(.leading, metrics.screenLeading(shellPaysLeading: shellPaysLeading))
            .padding(.trailing, metrics.screenHInset)
            .padding(.top, 38)
            .padding(.bottom, 18)
        }
    }

    #if os(tvOS)
    /// Focusable clear, mirroring ValuePickerRow's focus chrome (tinted fill + ring, never a white
    /// system pill). Activated through stableTap so focus drift in the last frames of a click can't
    /// wipe the query from a neighbour's press.
    private func clearButton(vm: SearchViewModel) -> some View {
        Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(clearFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            .padding(12)
            .background(
                Circle().fill(clearFocused ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.clear))
            )
            .focusStroke(Circle(), isFocused: clearFocused)
            .focusResponse(.chip, isFocused: clearFocused)
            .focusable()
            .focused($clearFocused)
            .stableTap(isFocused: clearFocused) {
                // scheduleSearch runs off the query's own onChange, which clears the results.
                vm.query = ""
            }
            .accessibilityLabel(Text("search.clear"))
    }
    #endif

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
    }

    private func librarySection(items: [JellyfinItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "house.fill", title: "search.section.library", tint: .accentColor)
                .padding(.leading, leadingInset)
                .padding(.trailing, 50)

            RowScrollView(leading: leadingInset, trailing: 50, vertical: 20) {
                LazyHStack(spacing: 30) {
                    ForEach(items) { item in
                        FocusableCard {
                            destination = .library(item)
                        } content: { isFocused in
                            MediaCard(
                                item: item,
                                imageURL: dependencies.jellyfinImageService.imageURL(
                                    itemID: item.id,
                                    imageType: .primary,
                                    tag: item.imageTags?.primary,
                                    maxWidth: ImageWidth.card
                                ),
                                style: .poster,
                                isFocused: isFocused
                            )
                        }
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
