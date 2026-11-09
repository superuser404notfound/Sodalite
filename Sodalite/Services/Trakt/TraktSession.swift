import Foundation

nonisolated enum TraktConfig {
    /// From the `TRAKT_CLIENT_ID` build setting through Info.plist. Public by design: Trakt's device
    /// flow takes no client secret, and every request carries the id in a header anyway. Empty
    /// means this build has no Trakt app, and the feature stays hidden.
    static var clientID: String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty || raw.hasPrefix("$(") ? nil : raw
    }

    static var isAvailable: Bool { clientID != nil }
}

/// What one Jellyfin profile keeps about its Trakt connection, in the keychain under
/// `KeychainKeys.traktSession`. Per device on purpose: refresh tokens are single use, so two devices
/// sharing a pair through iCloud would end each other's session at the first refresh.
nonisolated struct TraktSession: Codable, Sendable, Equatable {
    var tokens: TraktTokens
    var username: String
    var isVIP: Bool
    var options: TraktOptions
    var cursors: TraktSyncCursors

    init(tokens: TraktTokens, username: String, isVIP: Bool,
         options: TraktOptions = TraktOptions(), cursors: TraktSyncCursors = TraktSyncCursors()) {
        self.tokens = tokens
        self.username = username
        self.isVIP = isVIP
        self.options = options
        self.cursors = cursors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decode(TraktTokens.self, forKey: .tokens)
        username = try c.decode(String.self, forKey: .username)
        isVIP = try c.decodeIfPresent(Bool.self, forKey: .isVIP) ?? false
        options = try c.decodeIfPresent(TraktOptions.self, forKey: .options) ?? TraktOptions()
        cursors = try c.decodeIfPresent(TraktSyncCursors.self, forKey: .cursors) ?? TraktSyncCursors()
    }
}

nonisolated struct TraktOptions: Codable, Sendable, Equatable {
    var scrobble = true
    var syncWatched = true
    var syncRatings = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scrobble = try c.decodeIfPresent(Bool.self, forKey: .scrobble) ?? true
        syncWatched = try c.decodeIfPresent(Bool.self, forKey: .syncWatched) ?? true
        syncRatings = try c.decodeIfPresent(Bool.self, forKey: .syncRatings) ?? true
    }
}

/// The Trakt activity stamps the last sync saw, so the next one only fetches what moved.
nonisolated struct TraktSyncCursors: Codable, Sendable, Equatable {
    var lastSyncAt: Date?
    var moviesWatchedAt: Date?
    var episodesWatchedAt: Date?
    var ratedAt: Date?
    var watchlistAt: Date?
    var listsAt: Date?
}
