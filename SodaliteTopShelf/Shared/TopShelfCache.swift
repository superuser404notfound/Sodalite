import Foundation

nonisolated private let log = ShelfLog(category: "Cache")

/// Last good shelf content, so a server that is briefly unreachable does not blank the shelf.
/// Items are cached, never URLs: `topShelfImageURL` embeds the access token, so a cached URL
/// goes stale the moment the token rotates and the shelf renders grey tiles. Image URLs are
/// rebuilt at render time from these items plus the current session. `nonisolated` because the
/// app compiles it too, for the artwork pass (Sodalite#218).
nonisolated struct TopShelfCache: Codable, Sendable {
    let serverURL: String
    let userID: String
    let resume: [TopShelfItem]
    let nextUp: [TopShelfItem]

    /// Best-effort throughout: an unwritable container or an undecodable file behaves exactly
    /// like no cache at all, which is the pre-cache behaviour.
    static func read() -> TopShelfCache? {
        guard let url = TopShelfCachePolicy.fileURL(),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(TopShelfCache.self, from: data)
        else { return nil }
        return cache
    }

    func write() {
        guard let url = TopShelfCachePolicy.fileURL(),
              let data = try? JSONEncoder().encode(self)
        else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.notice("cache write failed: \(error.localizedDescription)")
        }
    }

    /// Last good content, but only when it belongs to the session just read from the keychain.
    /// A cache from another server or profile is deleted rather than carried forward.
    static func usable(for session: SharedSession) -> TopShelfCache? {
        guard let stored = read() else { return nil }
        guard TopShelfCachePolicy.matches(cachedServerURL: stored.serverURL,
                                          cachedUserID: stored.userID,
                                          sessionServerURL: session.baseURL.absoluteString,
                                          sessionUserID: session.userID)
        else {
            TopShelfCachePolicy.delete()
            return nil
        }
        return stored
    }
}
