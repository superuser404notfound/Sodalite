import Foundation

/// Playback and appearance settings per Jellyfin profile (spec 2026-09-17, per-profile settings).
///
/// One store pair per `serverID:userID`, created on first use and cached. A profile without values
/// of its own is seeded with a copy: the pre-change device values during the one-time migration,
/// the last active profile afterwards. A copy is provisional per record kind until a real edit or a
/// cloud record replaces it, and CloudSync only ever uploads kinds that are not provisional, so a
/// copy can never overwrite the settings a profile already has on another device.
///
/// Provisional is tracked here and not through CloudSync's stamps on purpose: zone recreation, an
/// account change and "delete iCloud data" all drop every stamp, and a profile whose real settings
/// were keyed on a stamp would never be uploaded again.
@MainActor
final class ProfileSettingsRegistry {
    struct Settings {
        let playback: PlaybackPreferences
        let appearance: AppearancePreferences
    }

    private enum Keys {
        static let migrated = "profileSettings.migrated"
        static let lastActive = "profileSettings.lastActive"
        static let known = "profileSettings.knownProfiles"
        static let migrationSeedsMarked = "profileSettings.migrationSeedsMarked"
        static func provisional(_ key: ProfileKey, _ kind: ProfileRecordKind) -> String {
            "\(key.storageScope)/profileSettings.provisional.\(kind.rawValue)"
        }
        static func migrationSeed(_ key: ProfileKey, _ kind: ProfileRecordKind) -> String {
            "\(key.storageScope)/profileSettings.migrationSeed.\(kind.rawValue)"
        }
    }

    private struct SeedSource {
        let settings: Settings
        let homeScope: String
        let label: String
    }

    let defaults: UserDefaults
    let device: DevicePreferences
    /// The unprefixed keys every store used before this change: the pre-login fallback when no
    /// profile was ever active, the migration source, and where a legacy `settings-*` record from an
    /// older build is applied.
    private(set) var legacy: Settings

    /// Wired by the container once it exists.
    var activeKey: () -> ProfileKey? = { nil }
    var isApplyingCloudChanges: () -> Bool = { false }
    /// A local edit to a profile's playback, appearance or home values.
    var onLocalEdit: ((ProfileKey, ProfileRecordKind) -> Void)?
    /// A local edit to a device value, with the legacy record that carries it.
    var onDeviceEdit: ((CloudSyncStoreKey) -> Void)?

    private var cache: [ProfileKey: Settings] = [:]
    private var seeding = false
    private var lastActiveMemo: ProfileKey??

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let deviceSpace = PreferenceKeyspace(defaults: defaults, scope: nil)
        let device = DevicePreferences(keyspace: deviceSpace)
        self.device = device
        self.legacy = Self.makeLegacy(defaults: defaults, device: device)
        deviceSpace.onWrite = { [weak self] name in self?.noteDeviceWrite(name) }
        observeHomeEdits()
    }

    // MARK: Resolution

    /// The settings on screen: the active profile's, else the last active one's (splash, discovery
    /// and the profile picker look like the profile that was last used), else the legacy values.
    /// Writes `lastActiveKey` as a side effect, which touches UserDefaults only and nothing observable.
    var current: Settings {
        if let key = activeKey() {
            // Resolved BEFORE `lastActiveKey` moves. Seeding a profile that has no values of its own
            // reads that field to find the profile to copy from, so writing it first would make the
            // rule read "copy from myself", which never matches and silently hands every new profile
            // the legacy values instead of the settings this box was last used with.
            let settings = settings(for: key)
            if lastActiveKey != key { lastActiveKey = key }
            return settings
        }
        if let last = lastActiveKey, hasValues(last) {
            return settings(for: last)
        }
        return legacy
    }

    var lastActiveKey: ProfileKey? {
        get {
            if let memo = lastActiveMemo { return memo }
            let stored = defaults.string(forKey: Keys.lastActive).flatMap(ProfileKey.init(storageScope:))
            lastActiveMemo = .some(stored)
            return stored
        }
        set {
            lastActiveMemo = .some(newValue)
            defaults.set(newValue?.storageScope, forKey: Keys.lastActive)
            if let newValue {
                LogTap.shared.note("[ProfileSettings] active profile \(newValue.fingerprint)")
            }
        }
    }

    var knownProfiles: [ProfileKey] {
        knownScopes.compactMap(ProfileKey.init(storageScope:))
    }

    func hasValues(_ key: ProfileKey) -> Bool {
        knownScopes.contains(key.storageScope)
    }

    /// Seeding writes into an instance nobody has read yet, so it registers no observer and cannot
    /// invalidate a view that is in the middle of evaluating `current`.
    func settings(for key: ProfileKey) -> Settings {
        let settings = instance(for: key)
        if !hasValues(key) {
            seed(key, into: settings, from: defaultSource(for: key))
        }
        return settings
    }

    // MARK: Migration

    func migrateIfNeeded(profiles: [ProfileKey]) {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        var seeded = 0
        for key in profiles where !hasValues(key) {
            seed(key, into: instance(for: key), from: legacySource(for: key), migration: true)
            seeded += 1
        }
        defaults.set(true, forKey: Keys.migrated)
        defaults.set(true, forKey: Keys.migrationSeedsMarked)
        LogTap.shared.note("[ProfileSettings] migration: \(seeded) profile(s) seeded from the device values")
    }

    /// Installs that migrated before seeds were told apart: every copy they still hold dates from
    /// the days right after the migration, so it is read as one. Runs once.
    func markEarlierMigrationSeedsIfNeeded() {
        guard defaults.bool(forKey: Keys.migrated), !defaults.bool(forKey: Keys.migrationSeedsMarked) else { return }
        var marked = 0
        for key in knownProfiles {
            for kind in ProfileRecordKind.allCases where isProvisional(key, kind) {
                defaults.set(true, forKey: Keys.migrationSeed(key, kind))
                marked += 1
            }
        }
        defaults.set(true, forKey: Keys.migrationSeedsMarked)
        LogTap.shared.note("[ProfileSettings] \(marked) earlier migration seed(s) marked for upload")
    }

    /// Kinds still holding the value the migration gave them, untouched here and never answered
    /// by a cloud record.
    func unclaimedMigrationSeeds() -> [(key: ProfileKey, kind: ProfileRecordKind)] {
        knownProfiles.flatMap { key in
            ProfileRecordKind.allCases
                .filter { isProvisional(key, $0) && defaults.bool(forKey: Keys.migrationSeed(key, $0)) }
                .map { (key: key, kind: $0) }
        }
    }

    // MARK: Provisional copies

    func isProvisional(_ key: ProfileKey, _ kind: ProfileRecordKind) -> Bool {
        defaults.bool(forKey: Keys.provisional(key, kind))
    }

    func noteCloudApplied(_ key: ProfileKey, _ kind: ProfileRecordKind) {
        defaults.set(false, forKey: Keys.provisional(key, kind))
        defaults.removeObject(forKey: Keys.migrationSeed(key, kind))
    }

    /// A copy that is published from now on: the viewer pushed it, or it is a migration seed iCloud
    /// has nothing for.
    func claim(_ key: ProfileKey, _ kind: ProfileRecordKind) {
        guard isProvisional(key, kind) else { return }
        defaults.set(false, forKey: Keys.provisional(key, kind))
        defaults.removeObject(forKey: Keys.migrationSeed(key, kind))
        LogTap.shared.note("[ProfileSettings] \(key.fingerprint) \(kind.rawValue) claimed, syncs from now on")
    }

    /// A removed server's profiles leave the registry, so a push or an adoption stops republishing
    /// them. Their values stay on disk; the server coming back seeds them afresh.
    func forgetProfiles(onServer serverID: String) {
        let gone = knownProfiles.filter { $0.serverID == serverID }
        guard !gone.isEmpty else { return }
        let scopes = Set(gone.map(\.storageScope))
        defaults.set(knownScopes.filter { !scopes.contains($0) }, forKey: Keys.known)
        for key in gone { cache[key] = nil }
    }

    // MARK: Reset

    /// The caller has already removed the persistent domain; this drops what is held in memory, or
    /// the next edit would write a cached profile's values straight back.
    func resetAll() {
        cache = [:]
        lastActiveMemo = nil
        // Rebuilt over the wiped domain: the legacy stores parsed their values at launch too, and
        // applying a payload onto them only reaches the fields it carries (audit SYNC-R202).
        legacy = Self.makeLegacy(defaults: defaults, device: device)
    }

    private static func makeLegacy(defaults: UserDefaults, device: DevicePreferences) -> Settings {
        Settings(
            playback: PlaybackPreferences(store: defaults, scope: nil, device: device),
            appearance: AppearancePreferences(store: defaults, scope: nil, device: device)
        )
    }

    // MARK: Internals

    private var knownScopes: [String] {
        defaults.stringArray(forKey: Keys.known) ?? []
    }

    private func addKnown(_ key: ProfileKey) {
        var scopes = knownScopes
        guard !scopes.contains(key.storageScope) else { return }
        scopes.append(key.storageScope)
        defaults.set(scopes, forKey: Keys.known)
    }

    private func instance(for key: ProfileKey) -> Settings {
        if let cached = cache[key] { return cached }
        let playbackSpace = PreferenceKeyspace(defaults: defaults, scope: key.storageScope)
        let appearanceSpace = PreferenceKeyspace(defaults: defaults, scope: key.storageScope)
        let created = Settings(
            playback: PlaybackPreferences(keyspace: playbackSpace, device: device),
            appearance: AppearancePreferences(keyspace: appearanceSpace, device: device)
        )
        playbackSpace.onWrite = { [weak self] _ in self?.noteWrite(key, .playback) }
        appearanceSpace.onWrite = { [weak self] _ in self?.noteWrite(key, .appearance) }
        cache[key] = created
        return created
    }

    private func legacySource(for key: ProfileKey) -> SeedSource {
        SeedSource(settings: legacy, homeScope: key.serverID, label: "the device values")
    }

    /// Home rows name libraries of one server, so a copy from a profile on another server takes the
    /// target server's own pre-change rows instead.
    private func defaultSource(for key: ProfileKey) -> SeedSource {
        guard let last = lastActiveKey, last != key, hasValues(last) else {
            return legacySource(for: key)
        }
        return SeedSource(
            settings: instance(for: last),
            homeScope: last.serverID == key.serverID ? last.storageScope : key.serverID,
            label: "profile \(last.fingerprint)"
        )
    }

    private func seed(_ key: ProfileKey, into target: Settings, from source: SeedSource, migration: Bool = false) {
        seeding = true
        defer { seeding = false }
        ProfilePlaybackPayload(collecting: source.settings.playback, stamp: .distantPast).apply(to: target.playback)
        ProfileAppearancePayload(collecting: source.settings.appearance, stamp: .distantPast).apply(to: target.appearance)
        ProfileHomeStore.copy(fromScope: source.homeScope, toScope: key.storageScope)
        for kind in ProfileRecordKind.allCases {
            defaults.set(true, forKey: Keys.provisional(key, kind))
            if migration { defaults.set(true, forKey: Keys.migrationSeed(key, kind)) }
        }
        addKnown(key)
        LogTap.shared.note("[ProfileSettings] seeded \(key.fingerprint) from \(source.label)")
    }

    private func noteWrite(_ key: ProfileKey, _ kind: ProfileRecordKind) {
        guard !seeding, !isApplyingCloudChanges() else { return }
        if isProvisional(key, kind) {
            defaults.set(false, forKey: Keys.provisional(key, kind))
            defaults.removeObject(forKey: Keys.migrationSeed(key, kind))
            LogTap.shared.note("[ProfileSettings] \(key.fingerprint) \(kind.rawValue) edited, syncs from now on")
        }
        onLocalEdit?(key, kind)
    }

    private func noteDeviceWrite(_ name: String) {
        guard !isApplyingCloudChanges() else { return }
        onDeviceEdit?(name.hasPrefix("appearance.") ? .appearance : .playback)
    }

    /// Synchronous on purpose, like CloudSync's own observer of the same notifications: the cloud
    /// apply path posts them while `isApplyingCloudChanges` is still set.
    ///
    /// The tokens are deliberately not kept. One registry lives as long as the app, and the block
    /// holds `self` weakly, so a registry that is released (every test container) leaves an observer
    /// that finds no `self` and returns. Storing them bought a list nothing read.
    private func observeHomeEdits() {
        for name in [Notification.Name.homeConfigDidChange, .librarySortDidChange] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let key = self.activeKey(), self.hasValues(key) else { return }
                    self.noteWrite(key, .home)
                }
            }
        }
    }
}
