import Foundation
import Testing
@testable import Sodalite

@Suite("Per-profile settings in the container", .serialized)
@MainActor
struct ProfileSettingsContainerTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profileContainer.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Held by the suite instance: `DependencyContainer.appState` is weak, and a state that only lives
    /// in a discarded tuple element is gone before the first read, which silently leaves no profile active.
    private let state = AppState()

    private func signedIn(_ defaults: UserDefaults, as userID: String, server: String) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults)
        container.appState = state
        let jellyfin = JellyfinServer(id: server, name: "Main", url: URL(string: "https://jf.example")!, version: "10.10")
        try container.addServer(jellyfin)
        state.setAuthenticated(
            server: jellyfin,
            user: JellyfinUser(id: userID, name: userID, serverID: server, hasPassword: true, primaryImageTag: nil, policy: nil)
        )
        #expect(container.activeProfileKey == ProfileKey(serverID: server, userID: userID))
        return container
    }

    @Test func aLegacyRecordNeverReachesTheActiveProfile() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("legacyApply"), as: "alice", server: server)
        container.appearancePreferences.largeCards = false
        guard case .appearance(var payload) = container.collectSettingsPayload(.appearance, stamp: .now) else {
            Issue.record("wrong case"); return
        }
        payload.largeCards = true
        payload.showTopShelfRow = false

        container.applySettingsPayload(.appearance(payload))

        #expect(container.appearancePreferences.largeCards == false)
        #expect(container.profileSettings.legacy.appearance.largeCards == true)
        // The sender's box, not this one: a record from another Apple TV must not switch this row.
        #expect(container.devicePreferences.showTopShelfRow == true)
    }

    @Test func aLegacyPlaybackRecordLeavesThisBoxsValuesAlone() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("deviceValues"), as: "alice", server: server)
        container.devicePreferences.forceDolbyVisionOnNonDVDisplay = false
        container.devicePreferences.preferLosslessAudioBridge = false
        guard case .playback(var payload) = container.collectSettingsPayload(.playback, stamp: .now) else {
            Issue.record("wrong case"); return
        }
        payload.forceDolbyVisionOnNonDVDisplay = true
        payload.preferLosslessAudioBridge = true
        payload.autoSkipIntro = !payload.autoSkipIntro

        container.applySettingsPayload(.playback(payload))

        #expect(container.devicePreferences.forceDolbyVisionOnNonDVDisplay == false)
        #expect(container.devicePreferences.preferLosslessAudioBridge == false)
        #expect(container.profileSettings.legacy.playback.autoSkipIntro == payload.autoSkipIntro)
    }

    /// An appearance record from a build that predates the Top Shelf values makes no statement about
    /// this box. Defaulting them switched the row back on for an Apple TV that had turned it off.
    @Test func aRecordWithoutTopShelfValuesLeavesThemAlone() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("noTopShelf"), as: "alice", server: server)
        container.devicePreferences.showTopShelfRow = false
        guard case .appearance(var payload) = container.collectSettingsPayload(.appearance, stamp: .now) else {
            Issue.record("wrong case"); return
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object["showTopShelfRow"] = nil
        object["topShelfImage"] = nil
        payload = try JSONDecoder().decode(
            AppearanceSettingsPayload.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(payload.showTopShelfRow == nil)

        container.applySettingsPayload(.appearance(payload))

        #expect(container.devicePreferences.showTopShelfRow == false)
    }

    /// Same shape for the parental record: one from before entry locks (#105) must not unlock them.
    @Test func aRecordWithoutEntryLocksKeepsThem() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("noEntryLocks"), as: "alice", server: server)
        container.parentalControlsPreferences.entryLockedProfileIDs = ["\(server):alice"]
        defer { container.parentalControlsPreferences.entryLockedProfileIDs = [] }

        container.applySettingsPayload(.parentalControls(ParentalControlsSettingsPayload(
            updatedAt: .now, protectedProfileIDs: ["\(server):kid"], entryLockedProfileIDs: nil
        )))

        #expect(container.parentalControlsPreferences.entryLockedProfileIDs == ["\(server):alice"])
        #expect(container.parentalControlsPreferences.protectedProfileIDs.contains("\(server):kid"))
    }

    @Test func theLegacyRecordMirrorsTheProfileItWasCapturedFor() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("mirror"), as: "alice", server: server)
        let bob = ProfileKey(serverID: server, userID: "bob")
        container.playbackPreferences.subtitleFontSize = .xlarge
        container.profileSettings.settings(for: bob).playback.subtitleFontSize = .small

        guard case .playback(let active) = container.collectSettingsPayload(.playback, stamp: .now),
              case .playback(let captured) = container.collectSettingsPayload(.playback, stamp: .now, profile: bob)
        else { Issue.record("wrong case"); return }

        #expect(active.subtitleFontSize == "xlarge")
        #expect(captured.subtitleFontSize == "small")
    }

    /// Audit 2026-11-17 SYNC-203: the record is built when the engine asks for it, and by then another
    /// profile may be active. It has to carry the profile the edit was made in.
    @Test func theLegacyRecordIsBuiltFromTheProfileItWasEditedIn() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("legacySend"), as: "alice", server: server)
        let prefs = CloudSyncPreferences(store: scratch("legacySendSync"))
        prefs.adoptionCompleted = true
        let service = CloudSyncService(dependencies: container, preferences: prefs)
        let bob = ProfileKey(serverID: server, userID: "bob")
        container.profileSettings.settings(for: bob).playback.subtitleFontSize = .small
        container.playbackPreferences.subtitleFontSize = .xlarge

        state.setAuthenticated(
            server: container.listKnownServers()[0],
            user: JellyfinUser(id: "bob", name: "bob", serverID: server, hasPassword: true, primaryImageTag: nil, policy: nil)
        )
        #expect(container.activeProfileKey == bob)
        #expect(container.playbackPreferences.subtitleFontSize == .small)

        let data = try #require(service.encodeLocalPayload(recordName: CloudSyncRecordName.settings(.playback), stamp: .now))
        let record = try JSONDecoder().decode(PlaybackSettingsPayload.self, from: data)
        #expect(record.subtitleFontSize == "xlarge")
        withExtendedLifetime(service) {}
    }

    /// Audit 2026-11-17 SYNC-R202: a reset used to leave the late fields of the legacy stores in memory,
    /// and the next profile seeded from them.
    @Test func aResetRebuildsTheLegacyStoresIncludingTheLateFields() throws {
        let suite = "profileContainer.legacyReset"
        let defaults = scratch("legacyReset")
        let registry = ProfileSettingsRegistry(defaults: defaults)
        let virgin = ProfileSettingsRegistry(defaults: scratch("legacyResetVirgin"))
        registry.legacy.playback.playThemeSongs.toggle()
        registry.legacy.playback.autoSkipCommercials.toggle()
        registry.legacy.appearance.showPosterRating.toggle()
        registry.legacy.appearance.setTabOrder(["settings", "home"])

        defaults.removePersistentDomain(forName: suite)
        registry.resetAll()

        #expect(registry.legacy.playback.playThemeSongs == virgin.legacy.playback.playThemeSongs)
        #expect(registry.legacy.playback.autoSkipCommercials == virgin.legacy.playback.autoSkipCommercials)
        #expect(registry.legacy.appearance.showPosterRating == virgin.legacy.appearance.showPosterRating)
        #expect(registry.legacy.appearance.tabOrder == virgin.legacy.appearance.tabOrder)
    }

    /// The legacy record goes through the profile mapping now: what it carries lands, what it does
    /// not carry stays, and the device values never move.
    @Test func aLegacyPlaybackRecordKeepsTheFieldsItDoesNotCarry() throws {
        let container = try signedIn(scratch("legacyLate"), as: "alice", server: "c-\(UUID().uuidString)")
        guard case .playback(var payload) = container.collectSettingsPayload(.playback, stamp: .now) else {
            Issue.record("wrong case"); return
        }
        let store = container.profileSettings.legacy.playback
        store.subtitlesOnSkipBack = true
        store.autoSkipRecap = true
        store.playThemeSongs = false
        payload.subtitlesOnSkipBack = nil
        payload.autoSkipRecap = nil
        payload.skipForwardSeconds = nil
        payload.skipBackwardSeconds = nil
        payload.skipIntervalSeconds = 45
        payload.subtitleFontSize = "no-such-size"
        payload.networkBufferDepth = "unlimited"

        container.applySettingsPayload(.playback(payload))

        #expect(store.subtitlesOnSkipBack)
        #expect(store.autoSkipRecap)
        #expect(!store.playThemeSongs)
        #expect(store.skipForwardSeconds == 45)
        #expect(store.skipBackwardSeconds == 45)
        #expect(store.subtitleFontSize == PlaybackPreferences(store: scratch("legacyLateVirgin")).subtitleFontSize)
        #expect(container.devicePreferences.networkBufferDepth != .unlimited)
    }

    @Test func aProfileRecordIsAppliedWithoutCountingAsAnEdit() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("profileApply"), as: "alice", server: server)
        let bob = ProfileKey(serverID: server, userID: "bob")
        var edits = 0
        container.profileSettings.onLocalEdit = { _, _ in edits += 1 }
        let source = AppearancePreferences(store: scratch("profileApplySource"))
        source.accentChoice = .gold

        container.applyProfilePayload(.appearance(ProfileAppearancePayload(collecting: source, stamp: .now)), key: bob)

        #expect(edits == 0)
        #expect(container.profileSettings.settings(for: bob).appearance.accentChoice == .gold)
        #expect(!container.profileSettings.isProvisional(bob, .appearance))
        #expect(container.profileSettings.isProvisional(bob, .playback))
    }

    @Test func aProfileWithoutValuesHasNothingToCollect() throws {
        let container = try signedIn(scratch("collectNil"), as: "alice", server: "c-\(UUID().uuidString)")
        #expect(container.collectProfilePayload(.playback, key: ProfileKey(serverID: "x", userID: "nobody"), stamp: .now) == nil)
    }

    @Test func theServerRecordMirrorsTheHomeRowsOfTheProfileLastSignedInThere() throws {
        let server = "c-\(UUID().uuidString)"
        let keychain = InMemoryKeychain()
        let container = DependencyContainer(keychainService: keychain, defaults: scratch("serverHome"))
        try container.addServer(JellyfinServer(id: server, name: "Main", url: URL(string: "https://jf.example")!, version: "10.10"))
        try keychain.save("alice", for: KeychainKeys.userID(serverID: server))
        let alice = ProfileKey(serverID: server, userID: "alice")
        _ = container.profileSettings.settings(for: alice)
        HomeRowConfig.setMergeContinueWatchingNextUp(true, scope: alice.storageScope)
        HomeRowConfig.setMergeContinueWatchingNextUp(false, scope: server)

        let payload = try #require(container.collectServerPayload(serverID: server, stamp: .now))

        #expect(payload.homeRows?.mergeCWNextUp == true)
    }

    @Test func launchMigratesEveryRememberedProfile() throws {
        let server = "c-\(UUID().uuidString)"
        let keychain = InMemoryKeychain()
        let setup = DependencyContainer(keychainService: keychain, defaults: scratch("launchSetup"))
        try setup.addServer(JellyfinServer(id: server, name: "Main", url: URL(string: "https://jf.example")!, version: "10.10"))
        try setup.rememberUser(RememberedUser(id: "alice", serverID: server, name: "alice", imageTag: nil, token: "t1"))
        try setup.rememberUser(RememberedUser(id: "bob", serverID: server, name: "bob", imageTag: nil, token: "t2"))
        let defaults = scratch("launch")
        PlaybackPreferences(store: defaults).autoSkipRecap = true

        let launched = DependencyContainer(keychainService: keychain, defaults: defaults)

        for user in ["alice", "bob"] {
            let key = ProfileKey(serverID: server, userID: user)
            #expect(launched.profileSettings.hasValues(key))
            #expect(launched.profileSettings.settings(for: key).playback.autoSkipRecap)
        }
    }
}
