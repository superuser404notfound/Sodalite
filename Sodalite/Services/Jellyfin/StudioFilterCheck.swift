import Foundation

/// Checks a `Studios=` answer against the studios the items actually carry. A server that only
/// emulates Jellyfin can skip the filter and answer with an unfiltered listing: AIOMetadata does
/// (every item comes back with `Studios: []`), so every provider tile showed the same first page
/// of movies (Discord, 2026-10-12). On Jellyfin itself nothing is dropped.
enum StudioFilterCheck {
    static func fields(_ fields: String) -> String {
        let names = fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if names.contains(where: { $0.caseInsensitiveCompare("Studios") == .orderedSame }) { return fields }
        return fields.isEmpty ? "Studios" : fields + ",Studios"
    }

    static func matches(_ item: JellyfinItem, studioNames: [String]) -> Bool {
        guard let studios = item.studios else { return false }
        return studios.contains { studio in
            studioNames.contains { $0.caseInsensitiveCompare(studio.name) == .orderedSame }
        }
    }

    /// The response with every item that carries none of the asked-for studios removed, plus how
    /// many that was. The total only changes when something was dropped, and then it is what is
    /// left: an ignored filter says nothing about how many items would have matched.
    static func filter(
        _ response: JellyfinItemsResponse,
        studioNames: [String]
    ) -> (response: JellyfinItemsResponse, dropped: Int) {
        let kept = response.items.filter { matches($0, studioNames: studioNames) }
        let dropped = response.items.count - kept.count
        guard dropped > 0 else { return (response, 0) }
        return (JellyfinItemsResponse(items: kept, totalRecordCount: kept.count), dropped)
    }
}
