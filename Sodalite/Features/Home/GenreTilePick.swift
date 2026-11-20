import Foundation

/// Picks the artwork item for each Genres tile. Each tile probes a few random items of its genre;
/// a candidate counts only if it really carries that genre, because a server that merely emulates
/// Jellyfin can ignore `Genres=` (and the random sort) and hand every tile the same first item
/// (Discord, 2026-10-25). Among the real matches a tile prefers one no earlier tile has taken, so
/// a small library does not paint the same poster across the row either.
enum GenreTilePick {
    static let candidateCount = 6

    static func fields(_ fields: String) -> String {
        let names = fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if names.contains(where: { $0.caseInsensitiveCompare("Genres") == .orderedSame }) { return fields }
        return fields.isEmpty ? "Genres" : fields + ",Genres"
    }

    static func carries(_ item: JellyfinItem, genre: String) -> Bool {
        item.genres?.contains { $0.caseInsensitiveCompare(genre) == .orderedSame } ?? false
    }

    /// One artwork item per tag, in tag order. A tag whose probe came back empty is absent (the
    /// genre has no movies or series); a tag whose probe found items but none carrying the genre maps
    /// to nil, so the tile stays and shows its name on the plain surface.
    static func pick(tags: [NamedItem], candidates: [String: [JellyfinItem]]) -> [String: JellyfinItem?] {
        var used = Set<String>()
        var picks: [String: JellyfinItem?] = [:]
        for tag in tags {
            guard let probe = candidates[tag.id], !probe.isEmpty else { continue }
            let matching = probe.filter { carries($0, genre: tag.name) }
            let item = matching.first { !used.contains($0.id) } ?? matching.first
            if let item { used.insert(item.id) }
            picks[tag.id] = .some(item)
        }
        return picks
    }
}
