import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync uploads profile records", .serialized)
@MainActor
struct CloudSyncProfileUploadTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profileUpload.\(name).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func setUp(_ name: String) -> (DependencyContainer, CloudSyncService, CloudSyncPreferences, ProfileKey, ProfileKey) {
        let server = "up-\(UUID().uuidString)"
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: scratch(name))
        let alice = ProfileKey(serverID: server, userID: "alice")
        let bob = ProfileKey(serverID: server, userID: "bob")
        container.profileSettings.migrateIfNeeded(profiles: [alice, bob])
        let prefs = CloudSyncPreferences(store: scratch("\(name).sync"))
        let service = CloudSyncService(dependencies: container, preferences: prefs)
        return (container, service, prefs, alice, bob)
    }

    @Test func adoptionUploadsEditedKindsOnly() {
        let (container, service, prefs, alice, bob) = setUp("adoption")
        container.profileSettings.settings(for: alice).playback.autoSkipIntro.toggle()

        service.completeAdoption()
        let saves = Set(prefs.drainPendingChanges().saves)

        #expect(saves.contains(CloudSyncRecordName.profile(.playback, alice)))
        #expect(!saves.contains(CloudSyncRecordName.profile(.appearance, alice)))
        #expect(!saves.contains { $0.hasSuffix(bob.storageScope) })
    }

    @Test func aProvisionalProfileNeverUploads() {
        let (container, service, prefs, _, bob) = setUp("provisional")

        service.uploadProfileIfChanged(.playback, bob)

        #expect(prefs.drainPendingChanges().saves.isEmpty)
        // The service holds its container unowned, as the app's one container outlives it.
        withExtendedLifetime(container) {}
    }

    @Test func theUploadCarriesTheProfileItWasScheduledFor() {
        let (container, service, prefs, alice, bob) = setUp("captured")
        container.profileSettings.settings(for: alice).appearance.largeCards.toggle()
        container.profileSettings.activeKey = { bob }

        service.uploadProfileIfChanged(.appearance, alice)

        // The legacy record for 1.0 builds goes out with the edit now, built from alice (audit SYNC-202, SYNC-203).
        #expect(prefs.drainPendingChanges().saves == [CloudSyncRecordName.profile(.appearance, alice), CloudSyncRecordName.settings(.appearance)])
    }

    @Test func anUnchangedProfileIsNotUploadedTwice() {
        let (container, service, prefs, alice, _) = setUp("twice")
        container.profileSettings.settings(for: alice).playback.autoSkipOutro.toggle()

        service.uploadProfileIfChanged(.playback, alice)
        _ = prefs.drainPendingChanges()
        service.uploadProfileIfChanged(.playback, alice)

        #expect(prefs.drainPendingChanges().saves.isEmpty)
    }

    /// A device that migrated and was never edited since holds only copies. The push is the viewer
    /// saying "these are my settings", so the active profile's copies go up; another profile's do not.
    @Test func aManualPushClaimsTheActiveProfilesCopies() {
        let (container, service, prefs, alice, bob) = setUp("push")
        _ = container.profileSettings.settings(for: alice)
        _ = container.profileSettings.settings(for: bob)
        container.profileSettings.activeKey = { alice }

        service.pushLocalSettingsToAllDevices()
        let saves = Set(prefs.drainPendingChanges().saves)

        for kind in ProfileRecordKind.allCases {
            #expect(saves.contains(CloudSyncRecordName.profile(kind, alice)))
            #expect(!container.profileSettings.isProvisional(alice, kind))
            #expect(!saves.contains(CloudSyncRecordName.profile(kind, bob)))
            #expect(container.profileSettings.isProvisional(bob, kind))
        }
    }

    @Test func aClaimedCopyKeepsSyncingAfterThePush() {
        let (container, service, prefs, alice, _) = setUp("claimed")
        container.profileSettings.activeKey = { alice }
        service.pushLocalSettingsToAllDevices()
        _ = prefs.drainPendingChanges()

        container.profileSettings.settings(for: alice).playback.autoSkipIntro.toggle()
        service.uploadProfileIfChanged(.playback, alice)

        #expect(prefs.drainPendingChanges().saves == [CloudSyncRecordName.profile(.playback, alice), CloudSyncRecordName.settings(.playback)])
    }

    @Test func aZoneRecreationStillReuploadsEditedProfiles() {
        let (container, service, prefs, alice, _) = setUp("zone")
        container.profileSettings.settings(for: alice).appearance.largeCards.toggle()
        service.uploadProfileIfChanged(.appearance, alice)
        _ = prefs.drainPendingChanges()

        prefs.resetForZoneRecreation()
        service.completeAdoption()

        #expect(prefs.drainPendingChanges().saves.contains(CloudSyncRecordName.profile(.appearance, alice)))
    }

    /// Settings first, then servers, then profiles: a profile record for an unknown profile seeds
    /// the kinds it does not carry from the other two.
    @Test func aBatchAppliesSettingsBeforeServersBeforeProfiles() {
        let key = ProfileKey(serverID: "s", userID: "u")
        let names = [
            CloudSyncRecordName.profile(.playback, key),
            CloudSyncRecordName.server(id: "s"),
            CloudSyncRecordName.securitySingleton,
            CloudSyncRecordName.settings(.playback),
        ]
        let ordered = names.sorted { CloudSyncService.applyOrder($0) < CloudSyncService.applyOrder($1) }
        #expect(ordered == [
            CloudSyncRecordName.settings(.playback),
            CloudSyncRecordName.server(id: "s"),
            CloudSyncRecordName.profile(.playback, key),
            CloudSyncRecordName.securitySingleton,
        ])
    }

    @Test func theLogSummaryNamesKindsNotIdentifiers() {
        let key = ProfileKey(serverID: "server-secret", userID: "user-secret")
        let summary = CloudSyncService.summary([
            CloudSyncRecordName.profile(.home, key),
            CloudSyncRecordName.profile(.home, ProfileKey(serverID: "server-secret", userID: "other")),
            CloudSyncRecordName.server(id: "server-secret"),
        ])
        #expect(summary == "profile-home×2, server×1")
        #expect(!summary.contains("secret"))
    }

    /// A save stays in the persistent outbox until CloudKit confirms it, so an app killed before the
    /// engine persisted its own queue still sends it on the next launch.
    @Test func anEditIsInTheOutboxTheMomentItIsMade() {
        let (container, service, prefs, alice, _) = setUp("outbox")
        container.profileSettings.settings(for: alice).playback.autoSkipIntro.toggle()

        service.uploadProfileIfChanged(.playback, alice)

        let name = CloudSyncRecordName.profile(.playback, alice)
        #expect(prefs.localStamp(for: name) != nil)
        #expect(prefs.drainPendingChanges().saves == [name, CloudSyncRecordName.settings(.playback)])
    }

    @Test func aConfirmedSaveLeavesTheOutbox() {
        let prefs = CloudSyncPreferences(store: scratch("unstash"))
        prefs.stashPendingSave("a")
        prefs.stashPendingSave("b")

        prefs.unstashPendingSave("a")

        #expect(prefs.drainPendingChanges().saves == ["b"])
    }

    @Test func anUnreadableRecordIsRememberedUntilItIsRead() {
        let prefs = CloudSyncPreferences(store: scratch("skipped"))
        prefs.noteSkippedRecord("settings-playback")
        prefs.noteSkippedRecord("settings-playback")
        #expect(prefs.skippedRecords == ["settings-playback"])

        prefs.clearSkippedRecord("settings-playback")
        #expect(prefs.skippedRecords.isEmpty)

        prefs.noteSkippedRecord("x")
        prefs.resetForZoneRecreation()
        #expect(prefs.skippedRecords.isEmpty)
    }
}
