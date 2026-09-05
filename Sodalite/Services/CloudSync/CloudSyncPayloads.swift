import Foundation

/// Wire types for CloudKit sync. Payloads travel as one JSON blob per record in
/// CKRecord.encryptedValues["payload"]; `updatedAt` drives last-writer-wins.
/// Enums travel as raw strings and map with keep-current fallback on apply, so
/// an older build never fails a whole payload on an unknown case.
enum CloudSyncRecordType {
    static let server = "SyncServer"
    static let settings = "SyncSettingsStore"
    static let security = "SyncSecurity"
}

enum CloudSyncStoreKey: String, CaseIterable, Codable {
    case playback
    case appearance
    case auth
    case seerrNotifications
    case parentalControls
    case trackMemory
    case spoilerReveals
    case spoilerSeriesRules
}

enum CloudSyncRecordName {
    static let securitySingleton = "security"

    static func server(id: String) -> String { "server-\(id)" }
    static func settings(_ key: CloudSyncStoreKey) -> String { "settings-\(key.rawValue)" }

    static func serverID(fromRecordName name: String) -> String? {
        guard name.hasPrefix("server-") else { return nil }
        return String(name.dropFirst("server-".count))
    }

    static func storeKey(fromRecordName name: String) -> CloudSyncStoreKey? {
        guard name.hasPrefix("settings-") else { return nil }
        return CloudSyncStoreKey(rawValue: String(name.dropFirst("settings-".count)))
    }
}

/// Per-server home row customization. configsJSON stays opaque raw JSON of
/// [HomeRowConfig] to preserve HomeRowConfig.loadFromStorage's lossy-decode
/// forward compatibility across app versions.
struct HomeRowsSyncState: Codable, Equatable {
    var configsJSON: Data?
    var mergeCWNextUp: Bool
    var rewatchNextUp: Bool
    /// CollectionGrouping raw value (Sodalite#44). Optional: payloads written before the field
    /// existed must still decode, and a missing value must not reset a device's local mode.
    var collectionGrouping: String?
    /// Per-tile library sort, scope key to `LibrarySort.storageValue` (Sodalite#78). Optional for the
    /// same reason as the field above; apply merges per scope, so a device that never opened a tile
    /// cannot erase another device's choice for it.
    var librarySorts: [String: String]?
}

struct ServerSyncPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var server: JellyfinServer
    var rememberedUsers: [RememberedUser]
    /// Legacy single-password fields, still written so older builds keep working: they carry
    /// whichever profile's password `jellyfinPasswords` holds for the sending device's active user.
    var jellyfinPassword: String?
    /// The user the legacy `jellyfinPassword` belongs to.
    var passwordUserID: String?
    /// Password per profile, keyed by Jellyfin user id. Optional: payloads written before the
    /// per-user layout must still decode, and a missing value must not wipe a device's passwords.
    var jellyfinPasswords: [String: String]?
    var seerrSessions: [RememberedSeerrSession]
    var homeRows: HomeRowsSyncState?
    /// Profile pinned as this server's default. Optional: payloads written before the pin moved out
    /// of the global auth store must still decode, and a missing value must not clear a device's pin.
    var defaultUserID: String?
    /// Profiles removed on purpose, keyed by profile id with the moment of removal (Sodalite#45).
    /// `rememberedUsers` unions on apply, so a removal travels here rather than as a shorter list,
    /// which a device whose list was merely behind would otherwise publish as an authoritative prune.
    /// The date is what lets a re-add take the removal back: see CloudSyncMerge.resolveRememberedUsers.
    /// Optional: a payload without it carries no removal.
    var forgottenUsers: [String: Date]?
    /// Whether this is the default server. Also moved off the global auth store (Sodalite#45): there
    /// a device that had never pinned anything published nil and cleared everyone else's pin, because
    /// "never pinned" and "deliberately cleared" are the same value there. Optional: keep-current.
    var isDefaultServer: Bool?
}

struct PlaybackSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var autoplayNextEpisode: Bool
    var autoSkipIntro: Bool
    var autoSkipOutro: Bool
    var nextEpisodeCountdownSeconds: Int
    var skipIntervalSeconds: Int
    var preferredAudioLanguage: String?
    var preferredSubtitleLanguage: String?
    var autoSubtitleForForeignAudio: Bool
    var styledASSSubtitles: Bool
    var subtitleFontSize: String
    var subtitleColor: String
    var subtitleBackground: String
    var subtitleDelaySeconds: Double
    var subtitleVerticalPosition: String
    var subtitleFont: String
    var subtitleWeight: String
    var pictureMode: String
    var showStatsForNerds: Bool
    var showEngineDiagnostics: Bool
    var preferLosslessAudioBridge: Bool
    var showScrubPreview: Bool
    var preferServerTrickplay: Bool
    /// The six below are optional because they were added after the payload shipped.
    /// Swift's synthesized Decodable does NOT fall back to a property default on a missing
    /// key, it throws, and one thrown key drops the whole payload: a device on an older
    /// build would silently stop syncing its playback settings to a newer one. A missing
    /// value means keep-current on apply, never reset.
    var playerRotationLocked: Bool?
    var networkBufferDepth: String?
    var rememberTrackSelections: Bool?
    var autoForcedSubtitles: Bool?
    var autoSkipRecap: Bool?
    var subtitlesOnSkipBack: Bool?
    /// Shipped after the payload, so optional for the same reason as the six above.
    var liveTeletextPage: String?
    /// Sodalite#67, same reason again.
    var autoplayCountdown: Bool?
    /// AetherEngine#455, same reason again.
    var forceDolbyVisionOnNonDVDisplay: Bool?
    /// Sodalite#114, same reason again. It replaces `selectTogglesPlayback` and `instantSkipSeek`,
    /// which are gone: both became the behaviour. A device still on the old build keeps writing them,
    /// and `CloudSyncForwardCompat` carries them through this build untouched, so its own switches
    /// keep working while nothing here reads them.
    var touchpadScrubbing: Bool?
}

/// Sodalite#46. Unlike the other settings payloads this one is NOT last-writer-wins:
/// each entry carries its own stamp and `CloudSyncMerge.unionTrackMemory` merges per key,
/// else a title watched on the Apple TV would erase one watched on the iPhone.
struct TrackMemoryPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var entries: [String: TrackMemoryEntry]
}

/// Sodalite#50. Like `TrackMemoryPayload` this is NOT last-writer-wins: each reveal carries its
/// own date and `CloudSyncMerge.unionSpoilerReveals` merges per key, else a reveal on the Apple TV
/// would erase one from the iPhone.
struct SpoilerRevealPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var entries: [String: Date]
}

/// Sodalite#50 follow-up. Per entry like the reveals, but merged by
/// `CloudSyncMerge.mergeSpoilerSeriesRules` rather than unioned: a union can only express "a rule
/// exists", and `shown` is the absence of veiling.
struct SpoilerSeriesRulesPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var entries: [String: SpoilerSeriesRuleEntry]
}

struct AppearanceSettingsPayload: Codable, Equatable {
    var schemaVersion: Int
    var updatedAt: Date
    var accentChoice: String
    var backgroundStyle: String
    var showContentLogos: Bool
    var continueWatchingImage: String
    var largeCards: Bool
    var nowPlayingUsesSeriesPoster: Bool
    var spoilerProtectionEnabled: Bool
    var spoilerHideEpisodes: Bool
    var spoilerHideMovies: Bool
    /// nil from a build without poster badges (Sodalite#79); false is the same as absent here,
    /// the badges are opt-in, so a plain default carries no risk of overriding an opinion.
    var showPosterBadges: Bool
    /// nil from a build without the Top Shelf switch. Defaults to TRUE, not false: absent means
    /// "that build had no opinion", and the row was on for everyone before the switch existed.
    var showTopShelfRow: Bool
    /// nil from a build without the library name switch (Sodalite#84); false is what those builds
    /// drew, so a plain default matches what the sender was actually showing.
    var showLibraryNames: Bool
    /// nil from a device on a build without tab visibility (Sodalite#62); applying nil would reset
    /// the receiver's hidden tabs, so it means "no opinion", not "nothing hidden".
    var hiddenTabs: [String]?

    init(
        schemaVersion: Int = 4,
        updatedAt: Date,
        accentChoice: String,
        backgroundStyle: String,
        showContentLogos: Bool,
        continueWatchingImage: String,
        largeCards: Bool,
        nowPlayingUsesSeriesPoster: Bool,
        spoilerProtectionEnabled: Bool = false,
        spoilerHideEpisodes: Bool = true,
        spoilerHideMovies: Bool = false,
        showPosterBadges: Bool = false,
        showTopShelfRow: Bool = true,
        showLibraryNames: Bool = false,
        hiddenTabs: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.accentChoice = accentChoice
        self.backgroundStyle = backgroundStyle
        self.showContentLogos = showContentLogos
        self.continueWatchingImage = continueWatchingImage
        self.largeCards = largeCards
        self.nowPlayingUsesSeriesPoster = nowPlayingUsesSeriesPoster
        self.spoilerProtectionEnabled = spoilerProtectionEnabled
        self.spoilerHideEpisodes = spoilerHideEpisodes
        self.spoilerHideMovies = spoilerHideMovies
        self.showPosterBadges = showPosterBadges
        self.showTopShelfRow = showTopShelfRow
        self.showLibraryNames = showLibraryNames
        self.hiddenTabs = hiddenTabs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case accentChoice
        case backgroundStyle
        case showContentLogos
        case continueWatchingImage
        case largeCards
        case nowPlayingUsesSeriesPoster
        case spoilerProtectionEnabled
        case spoilerHideEpisodes
        case spoilerHideMovies
        case showPosterBadges
        case showTopShelfRow
        case showLibraryNames
        case hiddenTabs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        accentChoice = try values.decode(String.self, forKey: .accentChoice)
        backgroundStyle = try values.decodeIfPresent(String.self, forKey: .backgroundStyle)
            ?? BackgroundStyle.graphiteGlass.rawValue
        showContentLogos = try values.decode(Bool.self, forKey: .showContentLogos)
        continueWatchingImage = try values.decode(String.self, forKey: .continueWatchingImage)
        largeCards = try values.decode(Bool.self, forKey: .largeCards)
        nowPlayingUsesSeriesPoster = try values.decode(
            Bool.self,
            forKey: .nowPlayingUsesSeriesPoster
        )
        spoilerProtectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .spoilerProtectionEnabled) ?? false
        spoilerHideEpisodes = try values.decodeIfPresent(Bool.self, forKey: .spoilerHideEpisodes) ?? true
        spoilerHideMovies = try values.decodeIfPresent(Bool.self, forKey: .spoilerHideMovies) ?? false
        showPosterBadges = try values.decodeIfPresent(Bool.self, forKey: .showPosterBadges) ?? false
        showTopShelfRow = try values.decodeIfPresent(Bool.self, forKey: .showTopShelfRow) ?? true
        showLibraryNames = try values.decodeIfPresent(Bool.self, forKey: .showLibraryNames) ?? false
        hiddenTabs = try values.decodeIfPresent([String].self, forKey: .hiddenTabs)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(4, forKey: .schemaVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(accentChoice, forKey: .accentChoice)
        try values.encode(backgroundStyle, forKey: .backgroundStyle)
        try values.encode(showContentLogos, forKey: .showContentLogos)
        try values.encode(continueWatchingImage, forKey: .continueWatchingImage)
        try values.encode(largeCards, forKey: .largeCards)
        try values.encode(nowPlayingUsesSeriesPoster, forKey: .nowPlayingUsesSeriesPoster)
        try values.encode(spoilerProtectionEnabled, forKey: .spoilerProtectionEnabled)
        try values.encode(spoilerHideEpisodes, forKey: .spoilerHideEpisodes)
        try values.encode(spoilerHideMovies, forKey: .spoilerHideMovies)
        try values.encode(showPosterBadges, forKey: .showPosterBadges)
        try values.encode(showTopShelfRow, forKey: .showTopShelfRow)
        try values.encode(showLibraryNames, forKey: .showLibraryNames)
        try values.encodeIfPresent(hiddenTabs, forKey: .hiddenTabs)
    }
}

struct AuthSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var launchBehavior: String
    /// Retired: the pin lives in `ServerSyncPayload.defaultUserID` now. Still written (mirroring the
    /// default server's pin) so a device on an older build keeps working; never applied on this build.
    var defaultUserID: String?
    var defaultServerID: String?
    /// Shipped after the payload, so a missing value means keep-current, not "off".
    var profileReprompt: String?
}

struct SeerrNotificationSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var notifyPendingRequests: Bool
}

struct ParentalControlsSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var protectedProfileIDs: [String]
    var entryLockedProfileIDs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case protectedProfileIDs
        case entryLockedProfileIDs
    }

    init(updatedAt: Date, protectedProfileIDs: [String], entryLockedProfileIDs: [String] = []) {
        self.updatedAt = updatedAt
        self.protectedProfileIDs = protectedProfileIDs
        self.entryLockedProfileIDs = entryLockedProfileIDs
    }

    /// A property default does not make a key optional to the synthesized decoder, and a record
    /// written before #105 carries no entry locks, so it is read as absent rather than as a failure
    /// of the whole settings record.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        protectedProfileIDs = try values.decode([String].self, forKey: .protectedProfileIDs)
        entryLockedProfileIDs = try values.decodeIfPresent([String].self, forKey: .entryLockedProfileIDs) ?? []
    }
}

struct SecuritySyncPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var pinBlob: GuardianPINCrypto.Blob
}

/// Type-erased settings payload so the engine can treat every settings store uniformly.
enum SettingsSyncPayload: Equatable {
    case playback(PlaybackSettingsPayload)
    case appearance(AppearanceSettingsPayload)
    case auth(AuthSettingsPayload)
    case seerrNotifications(SeerrNotificationSettingsPayload)
    case parentalControls(ParentalControlsSettingsPayload)
    case trackMemory(TrackMemoryPayload)
    case spoilerReveals(SpoilerRevealPayload)
    case spoilerSeriesRules(SpoilerSeriesRulesPayload)

    var storeKey: CloudSyncStoreKey {
        switch self {
        case .playback: .playback
        case .appearance: .appearance
        case .auth: .auth
        case .seerrNotifications: .seerrNotifications
        case .parentalControls: .parentalControls
        case .trackMemory: .trackMemory
        case .spoilerReveals: .spoilerReveals
        case .spoilerSeriesRules: .spoilerSeriesRules
        }
    }

    var updatedAt: Date {
        switch self {
        case .playback(let p): p.updatedAt
        case .appearance(let p): p.updatedAt
        case .auth(let p): p.updatedAt
        case .seerrNotifications(let p): p.updatedAt
        case .parentalControls(let p): p.updatedAt
        case .trackMemory(let t): t.updatedAt
        case .spoilerReveals(let s): s.updatedAt
        case .spoilerSeriesRules(let r): r.updatedAt
        }
    }

    /// Every field this build can write for this store, read off the stored properties rather than
    /// off an encoding. An optional that is nil right now is missing from the JSON but is very
    /// much known, and CloudSyncForwardCompat has to be able to tell those two apart.
    /// Pinned against the encoders by CloudSyncForwardCompatTests.
    var knownFields: Set<String> {
        switch self {
        case .playback(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .appearance(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .auth(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .seerrNotifications(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .parentalControls(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .trackMemory(let t): CloudSyncForwardCompat.storedPropertyNames(of: t)
        case .spoilerReveals(let s): CloudSyncForwardCompat.storedPropertyNames(of: s)
        case .spoilerSeriesRules(let r): CloudSyncForwardCompat.storedPropertyNames(of: r)
        }
    }

    func restamped(_ stamp: Date) -> SettingsSyncPayload {
        switch self {
        case .playback(var p): p.updatedAt = stamp; return .playback(p)
        case .appearance(var p): p.updatedAt = stamp; return .appearance(p)
        case .auth(var p): p.updatedAt = stamp; return .auth(p)
        case .seerrNotifications(var p): p.updatedAt = stamp; return .seerrNotifications(p)
        case .parentalControls(var p): p.updatedAt = stamp; return .parentalControls(p)
        case .trackMemory(var t): t.updatedAt = stamp; return .trackMemory(t)
        case .spoilerReveals(var s): s.updatedAt = stamp; return .spoilerReveals(s)
        case .spoilerSeriesRules(var r): r.updatedAt = stamp; return .spoilerSeriesRules(r)
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .playback(let p): try JSONEncoder().encode(p)
        case .appearance(let p): try JSONEncoder().encode(p)
        case .auth(let p): try JSONEncoder().encode(p)
        case .seerrNotifications(let p): try JSONEncoder().encode(p)
        case .parentalControls(let p): try JSONEncoder().encode(p)
        case .trackMemory(let t): try JSONEncoder().encode(t)
        case .spoilerReveals(let s): try JSONEncoder().encode(s)
        case .spoilerSeriesRules(let r): try JSONEncoder().encode(r)
        }
    }

    static func decode(_ data: Data, key: CloudSyncStoreKey) throws -> SettingsSyncPayload {
        switch key {
        case .playback: .playback(try JSONDecoder().decode(PlaybackSettingsPayload.self, from: data))
        case .appearance: .appearance(try JSONDecoder().decode(AppearanceSettingsPayload.self, from: data))
        case .auth: .auth(try JSONDecoder().decode(AuthSettingsPayload.self, from: data))
        case .seerrNotifications: .seerrNotifications(try JSONDecoder().decode(SeerrNotificationSettingsPayload.self, from: data))
        case .parentalControls: .parentalControls(try JSONDecoder().decode(ParentalControlsSettingsPayload.self, from: data))
        case .trackMemory: .trackMemory(try JSONDecoder().decode(TrackMemoryPayload.self, from: data))
        case .spoilerReveals: .spoilerReveals(try JSONDecoder().decode(SpoilerRevealPayload.self, from: data))
        case .spoilerSeriesRules: .spoilerSeriesRules(try JSONDecoder().decode(SpoilerSeriesRulesPayload.self, from: data))
        }
    }
}
