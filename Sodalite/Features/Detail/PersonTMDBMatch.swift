import Foundation

/// Which TMDB person a Jellyfin cast row belongs to when the server carries no provider id for it.
/// Kept out of the view model because these rules are the part that can silently attach a
/// stranger's filmography to the page (Sodalite#143).
enum PersonTMDBMatch {

    /// Seerr's `/search` ranks by TMDB popularity and returns partial-name hits for almost any
    /// query, so the name has to match exactly and unambiguously. Where two people share a name,
    /// the title the tap came from breaks the tie: only one of them is credited on it. `knownFor`
    /// carries TMDB's best-known credits rather than all of them, so the tie often stands, and a
    /// standing tie resolves to nothing.
    static func resolve(
        in candidates: [SeerrPersonSearchResult],
        name: String,
        sourceTMDBID: Int?
    ) -> Int? {
        let target = PersonLibrary.normalized(name)
        guard !target.isEmpty else { return nil }

        let named = candidates.filter { PersonLibrary.normalized($0.name) == target }
        if named.count == 1 { return named.first?.id }

        guard let sourceTMDBID else { return nil }
        let credited = named.filter { person in
            (person.knownFor ?? []).contains { $0.id == sourceTMDBID }
        }
        return credited.count == 1 ? credited.first?.id : nil
    }
}
