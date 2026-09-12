import Foundation
import os.log

private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "Cache")

/// Last good shelf content, so a server that is briefly unreachable does not blank the shelf.
/// Items are cached, never URLs: `topShelfImageURL` embeds the access token, so a cached URL
/// goes stale the moment the token rotates and the shelf renders grey tiles. Image URLs are
/// rebuilt at render time from these items plus the current session.
struct TopShelfCache: Codable, Sendable {
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
            log.notice("cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
