import SwiftUI

/// Person page: photo, biography, the person's own library titles, then the TMDB filmography.
/// A filmography tap routes to Jellyfin detail when the library owns the title, else to Seerr
/// detail to request it. Without Seerr the page keeps its Jellyfin half (Sodalite#57).
struct PersonDetailView: View {
    /// TMDB id when the caller already knows it (Seerr cast); nil for Jellyfin cast, where the view
    /// model translates `jellyfinPersonID` first and the wait sits behind this view's own spinner.
    let personID: Int?
    let jellyfinPersonID: String?
    /// Shown in the header until the detail fetch lands; pass "" if unknown.
    let personName: String
    /// TMDB id of the title the tap came from. Only used to tell two same-named TMDB people apart
    /// when the person has to be resolved by name (Sodalite#143).
    let sourceTMDBID: Int?

    init(personID: Int?, jellyfinPersonID: String? = nil, personName: String, sourceTMDBID: Int? = nil) {
        self.personID = personID
        self.jellyfinPersonID = jellyfinPersonID
        self.personName = personName
        self.sourceTMDBID = sourceTMDBID
    }

    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var viewModel: PersonDetailViewModel?

    @State private var navigateToJellyfinItem: JellyfinItem?
    @State private var navigateToSeerrMedia: SeerrMedia?

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var contentInset: CGFloat { hSizeClass == .compact ? metrics.gridInset : 80 }

    /// Adaptive on every tier, the same definition the catalog grid uses: five fixed 220pt columns
    /// left a third of a 4K row empty, adaptive fills it (six 233pt columns on tvOS, measured), and
    /// an iPad in portrait still wraps to what it fits.
    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: metrics.gridColumnMinimum(
                cardScale: dependencies.appearancePreferences.cardScale)),
            spacing: metrics.gridSpacing
        )]
    }

    var body: some View {
        content
            .themedStaticBackground()
            .hidesShellTabBar()
        .navigationDestination(item: $navigateToJellyfinItem) { item in
            DetailRouterView(item: item)
                .detailCoverPush()
        }
        .navigationDestination(item: $navigateToSeerrMedia) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .task { await bootstrap() }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel, !viewModel.isLoading {
            if let errorMessage = viewModel.errorMessage {
                errorState(message: errorMessage)
            } else {
                loadedContent(viewModel)
            }
        } else {
            // The name is all this view knows before the fetches land, and showing it makes the
            // push read as "this person is opening" rather than as a blank screen.
            VStack(spacing: 20) {
                ProgressView()
                if !personName.isEmpty {
                    Text(personName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadedContent(_ viewModel: PersonDetailViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 32) {
                    header(viewModel.profile)

                    if let bio = viewModel.profile?.biography, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("person.biography")
                                .font(.title3)
                                .fontWeight(.semibold)
                            ExpandableTextBox(text: bio)
                        }
                    }
                }
                .padding(.horizontal, contentInset)

                // Outside the padded column: the rows carry the same inset themselves, so a
                // focused card can grow into the margin instead of being clipped by it.
                librarySections(viewModel.library)

                switch viewModel.filmographyState {
                case .loaded:
                    filmographySection(viewModel.filmography)
                        .padding(.horizontal, contentInset)
                case .unavailable(let message):
                    filmographyNotice(message)
                        .padding(.horizontal, contentInset)
                // With no Seerr there is no filmography to be missing, so the heading goes too
                // rather than reporting an empty one.
                case .hidden:
                    EmptyView()
                }
            }
            .padding(.vertical, hSizeClass == .compact ? 24 : 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ profile: PersonProfile?) -> some View {
        // Compact stacks the photo above the name so neither gets squeezed on a phone; wider tiers keep the side-by-side hero.
        let photoSide: CGFloat = hSizeClass == .compact ? 140 : 200
        let photo = AsyncCachedImage(url: photoURL(profile)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Text(initials(profile))
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: photoSide, height: photoSide)
        .clipShape(Circle())

        let nameBlock = VStack(alignment: .leading, spacing: 8) {
            Text(displayName(profile))
                .font(.largeTitle)
                .fontWeight(.bold)

            if let dept = profile?.knownForDepartment, !dept.isEmpty {
                Text(verbatim: "\(String(localized: "person.knownFor", defaultValue: "Known for")): \(dept)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }

        return Group {
            if hSizeClass == .compact {
                VStack(alignment: .leading, spacing: 16) {
                    photo
                    nameBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 32) {
                    photo
                    nameBlock
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The person's own titles, above the filmography because a title already in the library beats
    /// one that would have to be requested. Each row appears only when it has something to show.
    @ViewBuilder
    private func librarySections(_ library: PersonLibraryResults) -> some View {
        if !library.movies.isEmpty {
            HorizontalMediaRow(
                title: "person.library.movies",
                items: library.movies,
                imageURLProvider: { dependencies.jellyfinImageService.posterURL(for: $0) },
                onItemSelected: { navigateToJellyfinItem = $0 },
                inset: contentInset
            )
        }
        if !library.series.isEmpty {
            HorizontalMediaRow(
                title: "person.library.series",
                items: library.series,
                imageURLProvider: { dependencies.jellyfinImageService.posterURL(for: $0) },
                onItemSelected: { navigateToJellyfinItem = $0 },
                inset: contentInset
            )
        }
        if !library.episodes.isEmpty {
            HorizontalMediaRow(
                title: "person.library.episodes",
                items: library.episodes,
                imageURLProvider: { dependencies.jellyfinImageService.episodeThumbnailURL(for: $0) },
                fallbackURLProvider: {
                    dependencies.jellyfinImageService.parentBackdropURL(
                        for: $0, maxWidth: ImageWidth.wideCard)
                },
                onItemSelected: { navigateToJellyfinItem = $0 },
                cardStyle: .landscape,
                inset: contentInset
            )
        }
    }

    private func filmographySection(_ filmography: [SeerrMedia]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("person.filmography")
                .font(.title3)
                .fontWeight(.semibold)

            if filmography.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("person.noTitles")
                        .foregroundStyle(.secondary)
                    Button {
                        dismiss()
                    } label: {
                        Text("common.back")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                }
            } else {
                // .leading so a short last row keeps the left edge the rows above have.
                LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                    // stableKey, not Identifiable's id: a filmography mixes
                    // movie and tv credits whose TMDB ids can collide.
                    ForEach(filmography, id: \.stableKey) { media in
                        FocusableCard {
                            handleTap(media)
                        } content: { focused in
                            SeerrMediaCard(media: media, isFocused: focused)
                        }
                    }
                }
            }
        }
    }

    /// Seerr is connected and still had nothing to give. Naming the reason keeps the page from
    /// reading like an app that cannot show a filmography at all (Sodalite#143).
    private func filmographyNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("person.filmography")
                .font(.title3)
                .fontWeight(.semibold)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            HStack(spacing: 16) {
                Button {
                    Task { await reload() }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, contentInset)
    }

    // MARK: - Derived

    private func displayName(_ profile: PersonProfile?) -> String {
        profile?.name ?? (personName.isEmpty ? " " : personName)
    }

    /// TMDB portrait when Seerr supplied the profile, else Jellyfin's own person image. The 140pt
    /// phone hero at 3x is the widest of the tiers, which is what `ImageWidth.avatar` is cut to.
    private func photoURL(_ profile: PersonProfile?) -> URL? {
        if let path = profile?.tmdbProfilePath {
            return SeerrImageURL.profile(path: path, size: .h632)
        }
        guard let id = profile?.jellyfinPersonID else { return nil }
        return dependencies.jellyfinImageService.personImageURL(
            personID: id, tag: profile?.jellyfinImageTag, maxWidth: ImageWidth.avatar
        )
    }

    private func initials(_ profile: PersonProfile?) -> String {
        let parts = displayName(profile).split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(displayName(profile).prefix(2)).uppercased()
    }

    // MARK: - Actions

    private func bootstrap() async {
        guard viewModel == nil else { return }
        let vm = PersonDetailViewModel(
            itemService: dependencies.jellyfinItemService,
            mediaService: dependencies.seerrMediaService,
            searchService: dependencies.seerrSearchService,
            // Follows the Catalog tab: with it hidden, the filmography would be the same catalog one level deeper (Sodalite#62).
            isSeerrConnected: SeerrSurfacePolicy.browsingEnabled(
                appState: appState,
                appearance: dependencies.appearancePreferences
            ),
            userID: appState.activeUser?.id
        )
        viewModel = vm
        await reload()
    }

    private func reload() async {
        await viewModel?.load(
            tmdbID: personID,
            jellyfinPersonID: jellyfinPersonID,
            name: personName,
            sourceTMDBID: sourceTMDBID
        )
    }

    /// Owned in Jellyfin routes to play; else to Seerr request. The library lookup runs only when Seerr marks the title available, so non-owned titles skip the query.
    private func handleTap(_ media: SeerrMedia) {
        Task {
            let status = media.mediaInfo?.status
            if status == .available || status == .partiallyAvailable,
               let userID = appState.activeUser?.id,
               let item = try? await dependencies.jellyfinItemService.findByTmdbID(
                   userID: userID, tmdbID: media.id, searchTerm: media.displayTitle
               ) {
                navigateToJellyfinItem = item
                return
            }
            navigateToSeerrMedia = media
        }
    }
}
