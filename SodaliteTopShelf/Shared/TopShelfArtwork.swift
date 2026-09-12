import Foundation

/// Which picture a Top Shelf cell shows, and the chain that resolves it against the tags an item
/// actually carries.
///
/// The choice is mirrored into the shared container the way `TopShelfAccent` is, because the
/// extension cannot read the app's preferences. It is a separate setting from the home screen's
/// Continue Watching image on purpose: a shelf cell is roughly three times the width of a card, so
/// an episode still that holds up in a row can be visibly soft up there, and the answer for one
/// surface is not automatically the answer for the other.
///
/// `nonisolated` throughout for the same reason as `TopShelfProgress`: the app targets default to
/// MainActor isolation, the extension defaults to nonisolated, and both compile this file.
enum TopShelfArtwork {

    /// Raw values match `AppearancePreferences.ContinueWatchingImage`, which is what the app
    /// writes here; `TopShelfArtworkTests` pins that the two lists cannot drift apart.
    enum Choice: String, CaseIterable, Sendable {
        case still
        case backdrop
        case thumb
    }

    /// What the shelf drew before there was a choice, so an untouched install keeps its picture.
    nonisolated static let fallback: Choice = .still

    nonisolated static let defaultsKey = "topshelf.artwork"

    nonisolated static func read() -> Choice {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let stored = defaults.string(forKey: defaultsKey),
              let choice = Choice(rawValue: stored)
        else { return fallback }
        return choice
    }

    nonisolated static func write(rawValue: String) {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              Choice(rawValue: rawValue) != nil
        else { return }
        defaults.set(rawValue, forKey: defaultsKey)
    }

    // MARK: - Resolution

    nonisolated enum Kind: String, Sendable {
        case primary = "Primary"
        case thumb = "Thumb"
        case backdrop = "Backdrop"
    }

    /// One image on one item: everything `Images/{kind}?tag=` needs.
    nonisolated struct Source: Equatable, Sendable {
        let itemID: String
        let kind: Kind
        let tag: String
    }

    /// The artwork an item advertises. Every link of every chain is tag-driven, so a picture the
    /// server does not have is never requested: a blind fetch that 404s would fail one burn-in
    /// candidate, and a shelf that cannot cover every cell drops the accent bar on all of them.
    nonisolated struct Available: Equatable, Sendable {
        var isEpisode: Bool
        var itemID: String
        var seriesID: String?
        var primary: String?
        var thumb: String?
        var backdrop: String?
        var parentBackdrop: String?
        /// Only sent by servers that fill `ParentThumbImageTag`. Where it is absent, Thumb falls
        /// through to the backdrop chain rather than guessing at a URL.
        var parentThumb: String?
        var parentThumbID: String?
    }

    /// Each choice is its own preference plus the chains below it, so a show without the picture
    /// that was asked for still draws something rather than dropping out of the shelf.
    nonisolated static func source(for choice: Choice, _ art: Available) -> Source? {
        switch choice {
        case .still:
            return still(art)
        case .backdrop:
            return backdrop(art) ?? still(art)
        case .thumb:
            return thumb(art) ?? backdrop(art) ?? still(art)
        }
    }

    /// Episodes prefer their own still (the parent backdrop for orphans), everything else its
    /// backdrop. This is what the shelf drew before the setting existed.
    nonisolated private static func still(_ art: Available) -> Source? {
        if art.isEpisode {
            if let tag = art.primary { return Source(itemID: art.itemID, kind: .primary, tag: tag) }
            if let tag = art.thumb { return Source(itemID: art.itemID, kind: .thumb, tag: tag) }
            if let series = art.seriesID, let tag = art.parentBackdrop {
                return Source(itemID: series, kind: .backdrop, tag: tag)
            }
        }
        if let tag = art.backdrop { return Source(itemID: art.itemID, kind: .backdrop, tag: tag) }
        if let tag = art.primary { return Source(itemID: art.itemID, kind: .primary, tag: tag) }
        return nil
    }

    nonisolated private static func backdrop(_ art: Available) -> Source? {
        if let tag = art.backdrop { return Source(itemID: art.itemID, kind: .backdrop, tag: tag) }
        if let series = art.seriesID, let tag = art.parentBackdrop {
            return Source(itemID: series, kind: .backdrop, tag: tag)
        }
        return nil
    }

    /// An episode takes the show's Thumb, not its own: the point of the option is promo art for the
    /// series, and an episode Thumb is the still again under another name.
    nonisolated private static func thumb(_ art: Available) -> Source? {
        if art.isEpisode {
            guard let owner = art.parentThumbID ?? art.seriesID, let tag = art.parentThumb else { return nil }
            return Source(itemID: owner, kind: .thumb, tag: tag)
        }
        if let tag = art.thumb { return Source(itemID: art.itemID, kind: .thumb, tag: tag) }
        return nil
    }
}
