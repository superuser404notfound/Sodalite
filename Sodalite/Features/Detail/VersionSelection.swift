import Foundation

/// Which version of a multi-source item the detail page describes and plays (Sodalite#139).
///
/// The choice used to live inside the Play press: the sheet opened, the viewer picked, the player
/// started, and nothing about it outlived that one launch. A visible button means the choice has to
/// survive the sheet, and anything that survives a sheet can outlive what it was chosen for, so the
/// pick is stored together with the item it belongs to. Every read takes the item it is asked about
/// and answers for that one: a source id is meaningless against a different item, and Jellyfin can
/// drop a version between fetches (an unmerge, a deleted file).
///
/// Untouched, the page stands on the BEST version the item offers, not on the server's first. That
/// is a deliberate deviation: Jellyfin sorts an item's own file ahead of its linked alternates "so
/// it is the default the client plays" (`BaseItem.GetMediaSources`), but which file became the item
/// is an accident of which one the scanner met first, not a statement about quality. On a 4K Apple
/// TV, a merged 4K version that only plays after a detour through a menu is a 4K version nobody
/// watches.
struct VersionSelection: Equatable {
    private var targetID: String?
    private var chosenID: String?

    /// The id playback must prefer: the pick while it still holds, the best version otherwise. Nil
    /// only where there is nothing to choose, so a single-source item keeps the exact path it had
    /// before any of this existed.
    func preferredSourceID(for item: JellyfinItem?) -> String? {
        guard let item, let sources = item.mediaSources, sources.count > 1 else { return nil }
        if targetID == item.id, let chosenID, sources.contains(where: { $0.id == chosenID }) {
            return chosenID
        }
        return sources.rankedByQuality().first?.id
    }

    /// The source the page describes, which is by construction the one Play starts.
    func resolvedSource(for item: JellyfinItem) -> MediaSource? {
        item.effectiveMediaSource(id: preferredSourceID(for: item))
    }

    mutating func choose(_ source: MediaSource, for item: JellyfinItem) {
        targetID = item.id
        chosenID = source.id
    }

    /// Two sources are what makes a choice; one, or a slim item whose query never asked for
    /// `MediaSources`, gets no button.
    static func isOffered(for item: JellyfinItem) -> Bool {
        (item.mediaSources?.count ?? 0) > 1
    }
}
