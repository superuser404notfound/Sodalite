import Foundation

/// What the Jellyfin library itself holds for a person, split into the three rows the person page
/// shows above the TMDB filmography (Sodalite#57).
struct PersonLibraryResults: Equatable, Sendable {
    var movies: [JellyfinItem] = []
    var series: [JellyfinItem] = []
    var episodes: [JellyfinItem] = []

    var isEmpty: Bool { movies.isEmpty && series.isEmpty && episodes.isEmpty }

    static let empty = PersonLibraryResults()
}

/// Resolving a person page onto the local library. Kept out of the view so the matching rules,
/// which are the part that can silently pick the wrong person, are testable on their own.
enum PersonLibrary {
    /// Enough for a prolific actor's shelf without turning three rows into a full library sweep.
    static let rowLimit = 60
    /// Name searches are narrow already; this only has to survive a handful of same-named people.
    static let personCandidateLimit = 12

    /// Which library person a page belongs to. The name search only narrows the field, the TMDB id
    /// decides, the same split `findByProviderIDs` uses for titles.
    ///
    /// A candidate carrying a *different* TMDB id is a different person, not a weak match, so it is
    /// out. People the server never identified stay eligible, since Jellyfin libraries routinely
    /// carry cast with no provider ids at all, but only while the name is unambiguous: two
    /// unidentified people of the same name cannot be told apart, and guessing would attach a
    /// stranger's filmography to the page.
    static func matchPerson(in candidates: [JellyfinItem], name: String, tmdbID: Int?) -> JellyfinItem? {
        // The id outranks the name: "Robert Downey Jr." and "Robert Downey, Jr." are the same person,
        // and a proven id must not lose to a punctuation difference.
        if let tmdbID, let identified = candidates.first(where: { $0.carriesProviderID("tmdb.\(tmdbID)") }) {
            return identified
        }

        let target = normalized(name)
        guard !target.isEmpty else { return nil }
        let named = candidates.filter { normalized($0.name) == target }
        guard tmdbID != nil else { return named.count == 1 ? named.first : nil }

        let unidentified = named.filter { $0.tmdbID == nil }
        return unidentified.count == 1 ? unidentified.first : nil
    }

    /// Jellyfin person id for the page. Cast taps inside the app already know it; a page reached
    /// from Seerr (catalog cast, the people row in search) knows only the TMDB id and pays one
    /// name search for it.
    static func resolvePersonID(
        itemService: JellyfinItemServiceProtocol,
        userID: String,
        jellyfinPersonID: String?,
        name: String,
        tmdbID: Int?
    ) async -> String? {
        if let jellyfinPersonID, !jellyfinPersonID.isEmpty { return jellyfinPersonID }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let candidates = try? await itemService.searchPersons(
            userID: userID, name: trimmed, limit: personCandidateLimit
        ) else { return nil }
        return matchPerson(in: candidates, name: trimmed, tmdbID: tmdbID)?.id
    }

    /// The three rows in parallel. Each type gets its own sort, and a failing row degrades to empty
    /// instead of taking the other two with it.
    static func load(
        itemService: JellyfinItemServiceProtocol,
        userID: String,
        personID: String
    ) async -> PersonLibraryResults {
        async let movies = items(
            itemService: itemService, userID: userID, personID: personID,
            type: .movie, sortBy: "PremiereDate", sortOrder: "Descending"
        )
        async let series = items(
            itemService: itemService, userID: userID, personID: personID,
            type: .series, sortBy: "PremiereDate", sortOrder: "Descending"
        )
        // Guest spots scatter across shows, so episodes read best grouped by series and in order.
        async let episodes = items(
            itemService: itemService, userID: userID, personID: personID,
            type: .episode, sortBy: "SeriesSortName,ParentIndexNumber,IndexNumber", sortOrder: "Ascending"
        )
        return await PersonLibraryResults(movies: movies, series: series, episodes: episodes)
    }

    private static func items(
        itemService: JellyfinItemServiceProtocol,
        userID: String,
        personID: String,
        type: ItemType,
        sortBy: String,
        sortOrder: String
    ) async -> [JellyfinItem] {
        let query = ItemQuery(
            includeItemTypes: [type],
            sortBy: sortBy,
            sortOrder: sortOrder,
            limit: rowLimit,
            personIDs: [personID],
            // Asked for on the wire so the row limit is spent on titles the library actually holds.
            isMissing: type == .episode ? false : nil,
            // Card rows need image tags only; a tap re-fetches full fields in the detail view.
            fields: JellyfinEndpoint.homeRowFields
        )
        let response = try? await itemService.getCollectionItems(userID: userID, query: query)
        return presentable(response?.items ?? [])
    }

    /// "In Your Library" has to mean it. A server with "display missing episodes" on lists episodes
    /// it holds no file for, and Jellyfin's `IsMissing` filter covers the missing ones but not the
    /// unaired ones, so the location decides here rather than the query (Sodalite#57).
    static func presentable(_ items: [JellyfinItem]) -> [JellyfinItem] {
        items.filter { !$0.isVirtual }
    }

    /// Shared with PersonTMDBMatch so a Jellyfin person and a TMDB one are compared by the same rule.
    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }
}
