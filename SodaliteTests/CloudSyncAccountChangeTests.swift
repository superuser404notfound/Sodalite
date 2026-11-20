import CloudKit
import Foundation
import Testing
@testable import Sodalite

/// What an iCloud sign-out or account switch while the app runs does to the sync bookkeeping, and why
/// a launch no longer re-uploads settings nobody changed.
@Suite("CloudSync account changes and launch uploads", .serialized)
@MainActor
struct CloudSyncAccountChangeTests {
    private func setUp(_ name: String) -> (DependencyContainer, CloudSyncService, CloudSyncPreferences) {
        let defaults = UserDefaults(suiteName: "accountChange.\(name).\(UUID().uuidString)")!
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults)
        let prefs = CloudSyncPreferences(store: UserDefaults(suiteName: "accountChange.\(name).sync.\(UUID().uuidString)")!)
        prefs.accountID = "_account-a"
        prefs.adoptionCompleted = true
        prefs.setLocalStamp(Date(timeIntervalSince1970: 100), for: CloudSyncRecordName.settings(.auth))
        return (container, CloudSyncService(dependencies: container, preferences: prefs), prefs)
    }

    /// The leak this closes: a sign-out wiped the account id, so the start after the next sign-in read
    /// as a first adoption and uploaded every server's credentials into whatever account that was.
    @Test func aSignOutKeepsTheAccountSoTheNextStartCanTellWhoCameBack() {
        let (container, service, prefs) = setUp("signOut")

        service.applyAccountChange(.signOut(previousUser: CKRecord.ID(recordName: "_account-a")))

        #expect(prefs.accountID == "_account-a")
        #expect(prefs.adoptionCompleted)
        #expect(prefs.localStamp(for: CloudSyncRecordName.settings(.auth)) != nil)
        #expect(prefs.isEnabled)
        #expect(service.status == .noAccount)
        #expect(CloudSyncAccountTransition.resolve(stored: prefs.accountID, current: "_account-b") == .changed)
        #expect(CloudSyncAccountTransition.resolve(stored: prefs.accountID, current: "_account-a") == .unchanged)
        withExtendedLifetime(container) {}
    }

    @Test func aSwitchLocksSyncOutInsteadOfAdoptingTheNewAccount() {
        let (container, service, prefs) = setUp("switch")

        service.applyAccountChange(.switchAccounts(
            previousUser: CKRecord.ID(recordName: "_account-a"),
            currentUser: CKRecord.ID(recordName: "_account-b")
        ))

        #expect(!prefs.isEnabled)
        #expect(prefs.accountChangeLocked)
        #expect(service.status == .accountChanged)
        withExtendedLifetime(container) {}
    }

    /// Vincent's device log showed six settings records going up on every launch with no edit. The
    /// observers fire on the session restore, and against an empty snapshot that read as a change.
    @Test func aLaunchWithoutAnEditUploadsNothing() {
        let (container, service, prefs) = setUp("launch")
        _ = prefs.drainPendingChanges()

        service.seedSettingsSnapshots()
        for key in CloudSyncStoreKey.allCases where !key.isProfileBacked {
            service.uploadSettingsIfChanged(key)
        }

        #expect(prefs.drainPendingChanges().saves.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test func aRealEditAfterTheSeedStillUploads() {
        let (container, service, prefs) = setUp("edit")
        _ = prefs.drainPendingChanges()
        service.seedSettingsSnapshots()

        container.seerrNotificationPreferences.notifyPendingRequests.toggle()
        service.uploadSettingsIfChanged(.seerrNotifications)

        #expect(prefs.drainPendingChanges().saves == [CloudSyncRecordName.settings(.seerrNotifications)])
    }

    /// Audit 2026-11-17 SYNC-202: the stamp and the outbox entry used to wait two seconds behind a
    /// debounce. An app killed inside that window seeded its next snapshot from the edited store, and
    /// the edit never went up. Nothing here waits for a timer, so a few turns of the run loop are all
    /// it takes for the edit to be on disk.
    @Test func anEditIsStampedAndQueuedWithoutWaitingForADebounce() async {
        let (container, service, prefs) = setUp("noDebounce")
        service.setEnabled(false)
        _ = prefs.drainPendingChanges()
        let name = CloudSyncRecordName.settings(.seerrNotifications)
        let before = prefs.localStamp(for: name)

        container.seerrNotificationPreferences.notifyPendingRequests.toggle()
        for _ in 0..<10 { await Task.yield() }

        #expect(prefs.localStamp(for: name) != before)
        #expect(prefs.drainPendingChanges().saves == [name])
        withExtendedLifetime(container) {}
    }

    /// The log after the settings fix still showed one server record going up on every launch: the
    /// restore re-saves the server and its profile, and every save marked the record.
    @Test func aRestoreThatChangesNothingDoesNotUploadTheServer() throws {
        let (container, service, prefs) = setUp("serverRestore")
        let server = JellyfinServer(id: "srv", name: "Main", url: URL(string: "https://jf.example")!, version: "10.10")
        try container.addServer(server)
        let user = RememberedUser(id: "u", serverID: "srv", name: "Vince", imageTag: nil, token: "t")
        try container.rememberUser(user)
        _ = prefs.drainPendingChanges()
        service.seedSettingsSnapshots()
        container.cloudSync = service
        defer { container.cloudSync = nil }

        try container.addServer(server)
        try container.rememberUser(user)
        #expect(prefs.drainPendingChanges().saves.isEmpty)

        try container.rememberUser(RememberedUser(id: "u", serverID: "srv", name: "Vincent", imageTag: nil, token: "t", addedAt: user.addedAt))
        #expect(prefs.drainPendingChanges().saves == [CloudSyncRecordName.server(id: "srv")])
    }

    // MARK: Switched off (audit 2026-09-25 CS-3, CS-5)

    /// Switching sync off on an adopted device used to drop every edit on the floor: the next start
    /// seeded its snapshots from the edited values and nothing ever went up, removals included.
    @Test func editsWhileSwitchedOffAreStampedAndQueuedForTheNextStart() {
        let (container, service, prefs) = setUp("offEdit")
        _ = prefs.drainPendingChanges()
        let before = prefs.localStamp(for: CloudSyncRecordName.settings(.auth))!

        service.setEnabled(false)
        // The switch itself is no edit.
        #expect(prefs.drainPendingChanges().saves.isEmpty)

        container.seerrNotificationPreferences.notifyPendingRequests.toggle()
        service.uploadSettingsIfChanged(.seerrNotifications)
        service.markSettingsDirty(.auth)
        service.markServerDeleted(serverID: "gone")

        let pending = prefs.drainPendingChanges()
        #expect(Set(pending.saves) == [CloudSyncRecordName.settings(.seerrNotifications),
                                       CloudSyncRecordName.settings(.auth)])
        #expect(pending.deletes == [CloudSyncRecordName.server(id: "gone")])
        // Stamped at the edit, so an older edit from another device loses to it once sync is back.
        #expect(prefs.localStamp(for: CloudSyncRecordName.settings(.auth))! > before)
        #expect(!prefs.isEnabled)
    }

    /// Log Out is local only: what is edited afterwards must not reach the zone on a later enable,
    /// which is a deliberate first adoption.
    @Test func afterLogOutNothingIsQueued() {
        let (container, service, prefs) = setUp("offLogout")
        service.handleFullLogout()

        service.markSettingsDirty(.auth)
        service.markServerDeleted(serverID: "gone")

        let pending = prefs.drainPendingChanges()
        #expect(pending.saves.isEmpty)
        #expect(pending.deletes.isEmpty)
        withExtendedLifetime(container) {}
    }

    /// The reset wiped the defaults domain after Log Out had written the off switch, and the next
    /// launch read the missing key as on and re-adopted the whole zone.
    @Test func aFactoryResetLeavesSyncOffAcrossALaunch() {
        let suite = "accountChange.reset.sync.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let prefs = CloudSyncPreferences(store: store)
        prefs.accountID = "_account-a"
        prefs.adoptionCompleted = true
        let container = DependencyContainer(keychainService: InMemoryKeychain(),
                                            defaults: UserDefaults(suiteName: "\(suite).app")!)
        let service = CloudSyncService(dependencies: container, preferences: prefs)

        service.handleFullLogout()
        store.removePersistentDomain(forName: suite)
        service.handleFactoryReset()

        let relaunched = CloudSyncPreferences(store: store)
        #expect(!relaunched.isEnabled)
        #expect(!relaunched.adoptionCompleted)
        #expect(relaunched.accountID == nil)
        #expect(!relaunched.accountChangeLocked)
        #expect(service.status == .disabled)
        store.removePersistentDomain(forName: suite)
    }
}
