import SwiftUI

struct CatalogDiscoverView: View {
    @Bindable var viewModel: CatalogViewModel
    var onSelect: (SeerrMedia) -> Void
    var onSelectFilter: (CatalogFilter) -> Void

    var body: some View {
        Group {
            if viewModel.isLoadingDiscover && viewModel.trending.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.trending.items.isEmpty {
                errorState(message: error)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 40) {
                        if !viewModel.trending.items.isEmpty {
                            SeerrHorizontalMediaRow(
                                title: "catalog.section.trending",
                                items: viewModel.trending.items,
                                isLoadingMore: viewModel.trending.isLoading,
                                onItemSelected: onSelect,
                                onNeedsMore: {
                                    Task { await viewModel.loadMore(row: .trending) }
                                }
                            )
                        }
                        if !viewModel.upcomingMovies.items.isEmpty {
                            SeerrHorizontalMediaRow(
                                title: "catalog.section.upcomingMovies",
                                items: viewModel.upcomingMovies.items,
                                isLoadingMore: viewModel.upcomingMovies.isLoading,
                                onItemSelected: onSelect,
                                onNeedsMore: {
                                    Task { await viewModel.loadMore(row: .upcomingMovies) }
                                }
                            )
                        }
                        if !viewModel.upcomingTV.items.isEmpty {
                            SeerrHorizontalMediaRow(
                                title: "catalog.section.upcomingShows",
                                items: viewModel.upcomingTV.items,
                                isLoadingMore: viewModel.upcomingTV.isLoading,
                                onItemSelected: onSelect,
                                onNeedsMore: {
                                    Task { await viewModel.loadMore(row: .upcomingTV) }
                                }
                            )
                        }
                        if !viewModel.popularMovies.items.isEmpty {
                            SeerrHorizontalMediaRow(
                                title: "catalog.section.popularMovies",
                                items: viewModel.popularMovies.items,
                                isLoadingMore: viewModel.popularMovies.isLoading,
                                onItemSelected: onSelect,
                                onNeedsMore: {
                                    Task { await viewModel.loadMore(row: .movies) }
                                }
                            )
                        }
                        if !viewModel.popularTV.items.isEmpty {
                            SeerrHorizontalMediaRow(
                                title: "catalog.section.popularShows",
                                items: viewModel.popularTV.items,
                                isLoadingMore: viewModel.popularTV.isLoading,
                                onItemSelected: onSelect,
                                onNeedsMore: {
                                    Task { await viewModel.loadMore(row: .tv) }
                                }
                            )
                        }
                        if !viewModel.movieGenres.isEmpty {
                            CatalogGenreRow(
                                titleKey: "catalog.section.movieGenres",
                                genres: viewModel.movieGenres,
                                kind: .movie,
                                onSelect: onSelectFilter
                            )
                        }
                        if !viewModel.tvGenres.isEmpty {
                            CatalogGenreRow(
                                titleKey: "catalog.section.tvGenres",
                                genres: viewModel.tvGenres,
                                kind: .tv,
                                onSelect: onSelectFilter
                            )
                        }
                        // Networks row drops tiles whose first page is known-empty. hidden*IDs are computed once per load in the VM; reading FilterCache here was ~41 sync disk reads + JSON decodes per body render.
                        let region = Locale.current.region?.identifier ?? "US"
                        let visibleNetworks = CatalogProviders.networks.filter {
                            !viewModel.hiddenNetworkIDs.contains($0.id)
                        }
                        if !visibleNetworks.isEmpty {
                            CatalogProviderRow(
                                titleKey: "catalog.section.networks",
                                providers: visibleNetworks,
                                onSelect: { provider in
                                    // Prefer the watch-providers filter (movies + tv) when the streamer has a TMDB id; fall back to TV-only network endpoint for broadcast networks (ABC, NBC, CBS) without one.
                                    if let providerID = provider.tmdbWatchProviderID {
                                        onSelectFilter(.streamingService(
                                            tmdbWatchProviderID: providerID,
                                            name: provider.name,
                                            region: region
                                        ))
                                    } else {
                                        onSelectFilter(.tvNetwork(id: provider.id, name: provider.name))
                                    }
                                },
                                backdropFor: { provider in
                                    SeerrImageURL.backdrop(
                                        path: viewModel.networkBackdrops[provider.id],
                                        size: .covering(ImageWidth.wideCard))
                                }
                            )
                        }
                        let visibleStudios = CatalogProviders.studios.filter {
                            !viewModel.hiddenStudioIDs.contains($0.id)
                        }
                        if !visibleStudios.isEmpty {
                            CatalogProviderRow(
                                titleKey: "catalog.section.studios",
                                providers: visibleStudios,
                                onSelect: { provider in
                                    onSelectFilter(.movieStudio(id: provider.id, name: provider.name))
                                },
                                backdropFor: { provider in
                                    SeerrImageURL.backdrop(
                                        path: viewModel.studioBackdrops[provider.id],
                                        size: .covering(ImageWidth.wideCard))
                                }
                            )
                        }
                    }
                    .padding(.vertical, 40)
                }
                .drivesShellBar()
            }
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.loadDiscover() }
            } label: {
                Text("home.retry")
                    .font(.body)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
