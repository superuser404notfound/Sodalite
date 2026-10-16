import Foundation

/// The app's episode-title spoiler decision, mirrored into the shared container like
/// `TopShelfArtwork`, because the extension cannot read the app's preferences or its reveal store.
///
/// Only what a shelf cell needs: the extension has no `played` flag, but nothing on the shelf is
/// played (Continue Watching is started, which reveals, and Next Up is unstarted), so the progress
/// it does carry is enough to apply the same reveal rule.
///
/// `nonisolated` for the same reason as `TopShelfArtwork`: both targets compile this file.
nonisolated struct TopShelfTitleVeil: Codable, Equatable, Sendable {
    /// What a show without a rule of its own does.
    var hidesByDefault: Bool
    /// Series id to "veil this show", the active profile's rules only.
    var seriesRules: [String: Bool]
    /// Item ids the viewer revealed by hand, the active profile's only.
    var revealedItemIDs: Set<String>

    static let off = TopShelfTitleVeil(hidesByDefault: false, seriesRules: [:], revealedItemIDs: [])

    static let defaultsKey = "topshelf.titleVeil"

    func hidesTitle(of item: TopShelfItem) -> Bool {
        guard item.type == .episode else { return false }
        let veiled = item.seriesId.flatMap { seriesRules[$0] } ?? hidesByDefault
        guard veiled else { return false }
        if (item.userData?.playedPercentage ?? 0) > 0 || (item.userData?.playbackPositionTicks ?? 0) > 0 {
            return false
        }
        return !revealedItemIDs.contains(item.id)
    }

    /// Absent or unreadable is off: every build before this one showed the title.
    static func read() -> TopShelfTitleVeil {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let data = defaults.data(forKey: defaultsKey),
              let veil = try? JSONDecoder().decode(TopShelfTitleVeil.self, from: data)
        else { return .off }
        return veil
    }

    static func write(_ veil: TopShelfTitleVeil) {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let data = try? JSONEncoder().encode(veil)
        else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
