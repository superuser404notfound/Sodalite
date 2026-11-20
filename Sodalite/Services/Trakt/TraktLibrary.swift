import Foundation

/// The active profile's library, read the way the Trakt sync and the Trakt rows need it.
struct TraktLibrary {
    var movies: [TraktLocalMovie] = []
    var series: [TraktLocalSeries] = []
    var episodes: [TraktLocalEpisode] = []

    /// Movies and series by every external key they carry, for the Trakt rows and the detail page.
    struct Index {
        var movies: [String: JellyfinItem] = [:]
        var series: [String: JellyfinItem] = [:]

        init(items: [JellyfinItem]) {
            for item in items {
                guard let ids = TraktIDs(item: item) else { continue }
                for key in TraktKey.keys(ids) {
                    switch item.type {
                    case .movie: movies[key] = movies[key] ?? item
                    case .series: series[key] = series[key] ?? item
                    default: break
                    }
                }
            }
        }

        func movie(_ ids: TraktIDs) -> JellyfinItem? {
            TraktKey.keys(ids).lazy.compactMap { movies[$0] }.first
        }

        func show(_ ids: TraktIDs) -> JellyfinItem? {
            TraktKey.keys(ids).lazy.compactMap { series[$0] }.first
        }
    }

    /// Movies and series with their provider ids. One query each, like the provider precompute.
    static func index(service: JellyfinLibraryServiceProtocol, userID: String) async throws -> Index {
        let query = ItemQuery(includeItemTypes: [.movie, .series], sortBy: "SortName", limit: 10_000,
                              fields: JellyfinEndpoint.homeRowFields)
        let items = try await service.getItems(userID: userID, query: query).items
        return Index(items: items)
    }

    /// `playedOnly` is the cheap pass for a sync whose Trakt side did not move: it only needs what
    /// Jellyfin has watched, to push. Series are always read in full, because the episode match
    /// runs on their ids.
    static func load(service: JellyfinLibraryServiceProtocol, userID: String,
                     playedOnly: Bool) async throws -> (TraktLibrary, Index) {
        let filters = playedOnly ? ["IsPlayed"] : nil
        async let movieItems = pages(service: service, userID: userID, types: [.movie], filters: filters,
                                     fields: "ProviderIds")
        async let seriesItems = pages(service: service, userID: userID, types: [.series], filters: nil,
                                      fields: JellyfinEndpoint.homeRowFields)
        async let episodeItems = pages(service: service, userID: userID, types: [.episode], filters: filters,
                                       fields: "")
        let (movies, series, episodes) = try await (movieItems, seriesItems, episodeItems)

        var library = TraktLibrary()
        library.movies = movies.compactMap { item in
            guard let ids = TraktIDs(item: item) else { return nil }
            return TraktLocalMovie(itemID: item.id, ids: ids, played: item.userData?.played == true,
                                   lastPlayed: item.userData?.lastPlayedDate.flatMap(TraktDate.parse),
                                   rating: item.userData?.rating, runTimeTicks: item.runTimeTicks,
                                   positionTicks: item.userData?.playbackPositionTicks)
        }
        library.series = series.compactMap { item in
            guard let ids = TraktIDs(item: item) else { return nil }
            return TraktLocalSeries(itemID: item.id, ids: ids, rating: item.userData?.rating)
        }
        library.episodes = episodes.compactMap { item in
            guard !item.isVirtual, let seriesID = item.seriesId,
                  let season = item.parentIndexNumber, let number = item.indexNumber
            else { return nil }
            return TraktLocalEpisode(itemID: item.id, seriesID: seriesID, season: season, number: number,
                                     played: item.userData?.played == true,
                                     lastPlayed: item.userData?.lastPlayedDate.flatMap(TraktDate.parse),
                                     rating: item.userData?.rating, runTimeTicks: item.runTimeTicks,
                                     positionTicks: item.userData?.playbackPositionTicks)
        }
        // The full movie list is only in hand when not filtered; the index wants every movie.
        let index = Index(items: series + (playedOnly ? [] : movies))
        return (library, index)
    }

    private static func pages(service: JellyfinLibraryServiceProtocol, userID: String, types: [ItemType],
                              filters: [String]?, fields: String) async throws -> [JellyfinItem] {
        let pageSize = 2_000
        var all: [JellyfinItem] = []
        var start = 0
        while true {
            var query = ItemQuery(includeItemTypes: types, sortBy: "SortName", limit: pageSize, fields: fields)
            query.startIndex = start
            query.filters = filters
            let page = try await service.getItems(userID: userID, query: query)
            all += page.items
            start += page.items.count
            if page.items.isEmpty || start >= page.totalRecordCount { return all }
        }
    }
}
