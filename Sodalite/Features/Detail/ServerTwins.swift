import Foundation

/// The same film on another combined server (Sodalite#240), with the media sources that server
/// holds for it.
///
/// A combined Home folds a title that lives on two servers into one card, and the card opens the
/// copy the merge rules picked (progress, then the active server). Its versions used to stop at
/// that server's files, so a 4K copy on the other server was unreachable from the page. The
/// version menu now lists those too, under their server's name.
struct ServerTwin: Identifiable, Equatable {
    let serverID: String
    let serverName: String
    /// Full detail, so its media sources are there to list.
    let item: JellyfinItem

    var id: String { item.originKey }

    static func == (lhs: ServerTwin, rhs: ServerTwin) -> Bool {
        lhs.id == rhs.id && lhs.serverName == rhs.serverName
            && lhs.item.selectableMediaSources.map(\.id) == rhs.item.selectableMediaSources.map(\.id)
    }
}

/// One other server to look on, and the account that reads it there.
struct TwinSource: Sendable {
    let serverID: String
    let serverName: String
    let userID: String
    let itemService: any JellyfinItemServiceProtocol
}

enum ServerTwins {
    /// Movies only. An episode's page is its series', so a version from another server would mean
    /// swapping the whole series under the viewer.
    static func isEligible(_ item: JellyfinItem) -> Bool {
        item.type == .movie && (item.tmdbID != nil || item.imdbID != nil || item.tvdbID != nil)
    }

    /// Titles to narrow each server's candidates by. Jellyfin has no provider-id filter, so a title
    /// search has to bring the twin into the candidate set, and two servers set to different
    /// metadata languages name the same film differently. The original title is the one both share.
    static func searchTerms(for item: JellyfinItem) -> [String] {
        var terms = [item.name]
        if let original = item.originalTitle?.trimmingCharacters(in: .whitespaces), !original.isEmpty,
           original.caseInsensitiveCompare(item.name) != .orderedSame {
            terms.append(original)
        }
        return terms
    }

    /// Every other server's copy, in `sources` order. A server that does not answer within
    /// `deadline` or holds no copy is left out; a copy with no playable source is too, since there
    /// would be nothing to pick.
    /// `pageServerID` is the server the page reads, for an item that came without a `ServerId`.
    static func find(
        for item: JellyfinItem,
        pageServerID: String? = nil,
        on sources: [TwinSource],
        deadline: Duration = .seconds(4)
    ) async -> [ServerTwin] {
        guard isEligible(item) else { return [] }
        let own = item.serverID ?? pageServerID
        let others = sources.filter { $0.serverID != own }
        guard !others.isEmpty else { return [] }
        let tmdb = item.tmdbID, tvdb = item.tvdbID, imdb = item.imdbID
        let type = item.type
        let terms = searchTerms(for: item)

        var found: [Int: JellyfinItem] = [:]
        await withTaskGroup(of: (Int, JellyfinItem?).self) { group in
            for (index, source) in others.enumerated() {
                group.addTask {
                    let detail = await Deadline.race(deadline) { () -> JellyfinItem? in
                        var hit: JellyfinItem?
                        for term in terms where hit == nil {
                            hit = try? await source.itemService.findByProviderIDs(
                                userID: source.userID, tmdbID: tmdb, tvdbID: tvdb, imdbID: imdb,
                                includeItemTypes: [type], searchTerm: term
                            )
                        }
                        guard let hit else { return nil }
                        return try? await source.itemService.getItemDetail(userID: source.userID, itemID: hit.id)
                    }
                    return (index, detail ?? nil)
                }
            }
            for await (index, detail) in group { found[index] = detail }
        }
        return others.indices.compactMap { index -> ServerTwin? in
            guard var detail = found[index], !detail.selectableMediaSources.isEmpty else { return nil }
            let source = others[index]
            if detail.serverID == nil { detail.serverID = source.serverID }
            return ServerTwin(serverID: source.serverID, serverName: source.serverName, item: detail)
        }
    }
}
