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
/// Nothing chosen means nothing preferred, deliberately: playback keeps the fallback it always had
/// (`PlaybackInfo`'s first source) rather than being handed an id the page derived from a second,
/// possibly differently ordered list.
struct VersionSelection: Equatable {
    private var targetID: String?
    private var chosenID: String?

    /// The id playback should prefer, or nil when the viewer has not chosen for this item.
    func preferredSourceID(for item: JellyfinItem?) -> String? {
        guard let item, targetID == item.id, let chosenID,
              item.mediaSources?.contains(where: { $0.id == chosenID }) == true else { return nil }
        return chosenID
    }

    /// The source the page describes: the pick when it still holds, the server's first otherwise.
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
