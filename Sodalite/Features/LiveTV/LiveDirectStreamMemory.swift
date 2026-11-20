import Foundation

/// Remembers the provider URL a live channel last direct-played from, so the next tune of that channel
/// hands it straight to the engine's HLS ingest.
///
/// Without it every zap pays two serialized Jellyfin round trips for a URL we already know: the
/// `AutoOpenLiveStream` PlaybackInfo (the server connects to the provider itself and ffprobes it, the
/// reason that endpoint carries a 60s timeout) and the awaited tuner close that follows it. Neither
/// buys anything on the direct route, where Jellyfin is out of the data path from the first byte.
///
/// Keychain rather than UserDefaults: an Xtream-style upstream carries the provider's username and
/// password in its path, so this is credential material and does not belong in a plist.
@MainActor
final class LiveDirectStreamMemory {

    struct Entry: Codable, Equatable {
        var url: String
        var updatedAt: Date
    }

    /// Bounded like `TrackSelectionMemory`: a large IPTV list must not grow the blob without limit.
    /// Eviction drops the least recently used entries.
    nonisolated static let maxEntries = 300

    /// A provider can re-point a channel in its m3u without the Jellyfin item id changing. A dead URL
    /// is caught by the load failing (the caller drops the entry and renegotiates), so this only bounds
    /// the rarer case of a URL that still resolves but no longer carries the channel it was stored for.
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// An unchanged URL is re-stamped at most this often, far inside `maxAge`.
    nonisolated static let refreshInterval: TimeInterval = 24 * 60 * 60

    private static let storageKey = KeychainKeys.liveDirectStreams

    private var entries: [String: Entry]
    private let keychain: KeychainServiceProtocol

    init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
        if let data = try? keychain.loadData(for: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    /// The user id keeps two profiles (and two servers) apart, matching `TrackSelectionMemory`.
    /// Plain strings, not a `JellyfinChannel`: the store has no business knowing the Jellyfin model.
    nonisolated static func scopeKey(userID: String, channelID: String) -> String {
        "\(userID)|\(channelID)"
    }

    /// The remembered upstream, or nil when there is none, it has expired, or it no longer parses.
    /// An expired entry is dropped on read so a channel that stopped being direct-eligible does not
    /// keep a dead row forever.
    func upstream(userID: String, channelID: String, now: Date = Date()) -> URL? {
        let key = Self.scopeKey(userID: userID, channelID: channelID)
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.updatedAt) < Self.maxAge else {
            entries.removeValue(forKey: key)
            persist()
            return nil
        }
        guard let url = URL(string: entry.url) else {
            entries.removeValue(forKey: key)
            persist()
            return nil
        }
        return url
    }

    /// Record a URL that just direct-played. Re-recording an unchanged URL still refreshes
    /// `updatedAt` (once a day), which is what keeps a channel in daily use from ever aging out.
    func remember(_ url: URL, userID: String, channelID: String, now: Date = Date()) {
        let key = Self.scopeKey(userID: userID, channelID: channelID)
        // Every successful tune lands here. An unchanged URL refreshed within the last day writes
        // nothing: the keychain blob is up to 300 entries, written on the main actor.
        if let existing = entries[key], existing.url == url.absoluteString,
           now.timeIntervalSince(existing.updatedAt) < Self.refreshInterval { return }
        entries[key] = Entry(url: url.absoluteString, updatedAt: now)
        entries = Self.capped(entries)
        persist()
    }

    /// Drop a URL that failed to play, so the next attempt renegotiates instead of retrying a dead one.
    func forget(userID: String, channelID: String) {
        guard entries.removeValue(forKey: Self.scopeKey(userID: userID, channelID: channelID)) != nil
        else { return }
        persist()
    }

    /// Drop everything a profile remembered. Called when the profile or its server is removed, so
    /// deleting an account takes the provider credentials in these URLs with it.
    func forgetAll(userID: String) {
        let prefix = "\(userID)|"
        let remaining = entries.filter { !$0.key.hasPrefix(prefix) }
        guard remaining.count != entries.count else { return }
        entries = remaining
        persist()
    }

    /// Pure over its argument so the eviction rule is testable without a keychain.
    nonisolated static func capped(_ entries: [String: Entry]) -> [String: Entry] {
        guard entries.count > maxEntries else { return entries }
        let kept = entries
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? keychain.save(data, for: Self.storageKey)
    }
}
