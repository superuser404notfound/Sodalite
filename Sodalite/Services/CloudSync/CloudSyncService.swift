import CloudKit
import Foundation
import Observation
import Security

enum CloudSyncStatus: Equatable {
    case disabled
    /// Sync is off because a different iCloud account signed in on this device.
    case accountChanged
    case noAccount
    case syncing
    case active(lastSyncAt: Date?)
    case error(String)
}

/// What a manual "load from iCloud" attempt amounted to. Distinguishing these is
/// the point: reporting every outcome as "nothing in iCloud" hides broken fetches.
enum CloudSyncLoadOutcome: Equatable {
    case loaded
    case empty
    case noAccount
    /// Carries CloudKit's message when there was one; nil when the engine never
    /// got far enough to produce one (sync still disabled).
    case failed(String?)

    /// "Empty" is a claim about the whole zone, so it needs a completed adoption fetch behind it. A
    /// healthy status alone only says nothing has failed YET: the engine reports active before its
    /// first fetch has run, and a tap in that window used to read an unfetched zone as an empty one.
    static func resolve(status: CloudSyncStatus, hasServers: Bool, adoptionCompleted: Bool) -> CloudSyncLoadOutcome {
        if hasServers { return .loaded }
        switch status {
        case .noAccount: return .noAccount
        case .error(let message): return .failed(message)
        case .disabled, .accountChanged: return .failed(nil)
        case .active, .syncing: return adoptionCompleted ? .empty : .failed(nil)
        }
    }
}

protocol CloudSyncServiceProtocol: AnyObject {
    var status: CloudSyncStatus { get }
    var isEnabled: Bool { get }
    func start()
    func setEnabled(_ enabled: Bool)
    func fetchNow() async
    func loadFromCloud() async -> CloudSyncLoadOutcome
    func waitForInitialSync(timeout: TimeInterval) async
    func markServerDirty(serverID: String)
    func markServerDeleted(serverID: String)
    func markSettingsDirty(_ key: CloudSyncStoreKey)
    func markSecurityDirty()
    func markSecurityDeleted()
    func pushLocalSettingsToAllDevices()
    func pullSettingsFromCloud() async
    func deleteCloudDataAndDisable() async
    func handleFullLogout()
    func handleFactoryReset()
}

/// Owns the CKSyncEngine on the private database. All state and delegate work is
/// MainActor (project default isolation); the async delegate requirements hop here.
@Observable
final class CloudSyncService: CloudSyncServiceProtocol {
    static let containerID = "iCloud.de.superuser404.Sodalite"
    static let zoneName = "SodaliteSync"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private static let payloadKey = "payload"

    private(set) var status: CloudSyncStatus = .disabled
    var isEnabled: Bool { preferences.isEnabled }

    private unowned let dependencies: DependencyContainer
    let preferences: CloudSyncPreferences
    private var engine: CKSyncEngine?
    /// The database the engine runs on, for the direct reads a delta fetch cannot answer: a pull
    /// of records this device already has, and whether a record exists at all.
    private var database: CKDatabase?
    /// Set for the length of a manual pull: settings and profile records apply cloud-wins.
    private var forcingCloudWins = false
    private var startInFlight = false
    /// The in-flight (or last) engine start, so callers that need a live engine can
    /// await it instead of no-opping while it is still coming up.
    private var startTask: Task<Void, Never>?
    private var debounceTasks: [CloudSyncStoreKey: Task<Void, Never>] = [:]
    /// Last snapshot uploaded or applied per store, to skip observation echoes.
    private var lastSettingsSnapshot: [CloudSyncStoreKey: SettingsSyncPayload] = [:]
    /// Last server payload queued or applied per server id. A session restore re-saves the server and
    /// its profile on every launch, and each save marked the record, so every launch uploaded it again.
    private var lastServerSnapshot: [String: ServerSyncPayload] = [:]
    /// Last profile payload uploaded or applied per record name, to skip unchanged re-uploads.
    private var lastProfileSnapshot: [String: ProfileSyncPayload] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Bumped on every teardown/start so stale withObservationTracking re-arm loops die.
    private var observationGeneration = 0
    /// Records queued for local deletion but not yet confirmed sent, so a remote
    /// fetch racing the delete cannot resurrect them via applyRemoteRecord.
    private var recentLocalDeletes: Set<String> = []
    /// In-flight zone resync, so the several records that report the same divergence in one
    /// batch trigger one recovery rather than one each.
    private var resyncTask: Task<Void, Never>?
    /// Bounded per session: a resync that does not fix the divergence must surface as an error
    /// instead of spinning fetch/send forever.
    private var resyncCount = 0
    private static let maxResyncsPerSession = 2
    /// Holds an upload failure the server will keep rejecting, so the next fetch (which succeeds
    /// against a zone this device has never written to) cannot report the row back to healthy.
    private var statusLatch = CloudSyncStatusLatch()
    /// Saves that came back "zone not found" after adoption, held until a fetch has said whether the
    /// zone was deleted on purpose.
    private var zoneMissingSaves: Set<String> = []
    private var zoneCheckTask: Task<Void, Never>?
    /// Set while this device deletes the zone itself: saves still in the same send fail against the
    /// zone being removed, and must not queue it for recreation.
    private var deletingZone = false
    private var zoneDeleteFailure: CKError?
    /// The stamp each record was built with for the send in flight. An edit that lands after the
    /// build re-adds a save the engine already holds, which is a no-op, and the engine then drops it
    /// on success: without comparing stamps the newer edit stayed local until the next one.
    private var inFlightStamps: [String: Date] = [:]

    init(dependencies: DependencyContainer, preferences: CloudSyncPreferences = CloudSyncPreferences()) {
        self.dependencies = dependencies
        self.preferences = preferences
        // Write hooks, not observation: a profile switch writes nothing, so it cannot upload
        // anything, and cloud applies and seeding are suppressed inside the registry.
        dependencies.profileSettings.onLocalEdit = { [weak self] key, kind in
            guard let self else { return }
            // Not debounced: the stamp and the queued save are written with the edit, so an app
            // killed a second later still uploads it on the next launch. A debounce here lost the
            // edit for good, and left the kind unstamped for the next incoming record to overwrite.
            self.uploadProfileIfChanged(kind, key)
            if let legacy = kind.legacyStoreKey {
                self.scheduleSettingsUpload(legacy, profile: key)
            }
        }
        dependencies.profileSettings.onDeviceEdit = { [weak self] legacy in
            guard let self else { return }
            self.scheduleSettingsUpload(legacy, profile: self.dependencies.activeProfileKey)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard preferences.isEnabled else {
            status = preferences.accountChangeLocked ? .accountChanged : .disabled
            observeWhileOff()
            return
        }
        guard Self.isEntitledForCloudKit else {
            status = .disabled
            LogTap.shared.note("[CloudSync] not started, this build carries no iCloud container entitlement")
            return
        }
        guard engine == nil, !startInFlight else { return }
        startInFlight = true
        removeObservers()
        observationGeneration += 1
        observeAccountChanges()
        seedSettingsSnapshots()
        observeSettingsStores()
        observeHomeConfigChanges()
        // In flight, not off: the fresh-install gate reads `.disabled` as final, and a status that
        // stayed there through the two CloudKit round trips below sent every new device straight
        // to discovery while its data was still on the way.
        if !isHealthy { status = .syncing }
        startTask = Task { await startEngine() }
    }

    /// Whether this build may reach CloudKit at all.
    ///
    /// `CKContainer(identifier:)` does not fail when the entitlement is missing, it traps, so the
    /// check has to come before the container is ever constructed, and a build without the
    /// entitlement dies on launch rather than reporting sync as unavailable. Measured on the Mac
    /// target: an unsigned local build aborts inside `CKContainer.__allocating_init` before a
    /// window appears.
    ///
    /// macOS only, because asking is macOS only: `SecTaskCreateFromSelf` is not public API on iOS
    /// or tvOS, and the alternative there is reading a provisioning profile that a simulator build
    /// does not have. It is also where the question arises, since a Mac app can be signed locally
    /// with no entitlements at all, while an iOS or tvOS build that reaches a device or a simulator
    /// was signed with them.
    private static let isEntitledForCloudKit: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(
                  task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String]
        else { return false }
        return containers.contains(containerID)
        #else
        return true
        #endif
    }()

    private var isHealthy: Bool {
        if case .active = status { return true }
        return false
    }

    /// Every settled "healthy" status goes through here so a latched upload failure survives it.
    private func settleActive() {
        status = statusLatch.resolve(.active(lastSyncAt: preferences.lastSyncAt))
    }

    /// An upload failure the server will repeat for the same record: show it, and keep showing it
    /// until an upload actually lands.
    private func latchFailure(_ message: String) {
        statusLatch.latch(message)
        status = .error(message)
    }

    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        // Either direction is the user's own hand on the switch, so the account-change
        // explanation has done its job and must not outlive it.
        preferences.accountChangeLocked = false
        statusLatch.clear()
        if enabled {
            start()
        } else {
            teardownEngine()
            status = .disabled
            observeWhileOff()
        }
    }

    /// Off on a device that has adopted the zone: nothing is sent, but every local edit is still
    /// stamped and kept in the outbox, so switching sync back on publishes what changed meanwhile,
    /// removals included, and an older edit from another device cannot overwrite it. Seeding the
    /// snapshots first keeps a session restore from reading as an edit, as it does in `start()`.
    private func observeWhileOff() {
        guard preferences.tracksLocalEdits else { return }
        removeObservers()
        observationGeneration += 1
        seedSettingsSnapshots()
        observeSettingsStores()
        observeHomeConfigChanges()
    }

    /// A different iCloud account than the one this device adopted against.
    ///
    /// Adopting again here is not a merge, it is an upload: `completeAdoption` marks every known
    /// server dirty unconditionally, and a server record carries its remembered profiles, their
    /// Jellyfin tokens, the stored password and the Seerr sessions. On a device that changed hands
    /// that lands the previous account's credentials in the new account's private database, without
    /// anyone asking for it. So sync stops here and stays stopped until someone turns it back on.
    ///
    /// Clearing the stored account is what makes that switch clean: the next enable reads as a
    /// first adoption for whoever is signed in now, rather than tripping this guard forever.
    private func lockOutForAccountChange() {
        preferences.resetForAccountChange()
        preferences.isEnabled = false
        preferences.accountChangeLocked = true
        statusLatch.clear()
        status = .accountChanged
        LogTap.shared.note("[CloudSync] iCloud account changed, sync paused until re-enabled")
    }

    private func teardownEngine() {
        observationGeneration += 1
        removeObservers()
        // An engine start that is still mid-flight would otherwise install its engine after this
        // teardown, and the next start() would bail at its `engine == nil` guard without ever
        // re-arming the observers: sync would look enabled and be deaf until the next launch.
        startTask?.cancel()
        startTask = nil
        engine = nil
        database = nil
        startInFlight = false
        for task in debounceTasks.values { task.cancel() }
        debounceTasks = [:]
        // A delete queued under one account must not block adoption of the same
        // record name under the next account.
        recentLocalDeletes = []
        zoneCheckTask?.cancel()
        zoneCheckTask = nil
        zoneMissingSaves = []
        inFlightStamps = [:]
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func startEngine() async {
        // Teardown bumps this, so a start that was superseded while awaiting CloudKit can tell
        // and stop touching shared state.
        let generation = observationGeneration
        defer { if observationGeneration == generation { startInFlight = false } }
        var stash: (saves: [String], deletes: [String]) = ([], [])
        do {
            let container = CKContainer(identifier: Self.containerID)
            let accountStatus = try await container.accountStatus()
            guard observationGeneration == generation else { return }
            guard accountStatus == .available else {
                status = .noAccount
                return
            }
            let accountID = try await container.userRecordID().recordName
            guard observationGeneration == generation else { return }
            let transition = CloudSyncAccountTransition.resolve(stored: preferences.accountID, current: accountID)
            // One line on every start, deliberately. Without it the absence of an account-change
            // line is indistinguishable from CloudSync never logging anything on a healthy device,
            // which is exactly the reading that cannot be made from a silent log.
            LogTap.shared.note(
                "[CloudSync] engine start, account \(CloudSyncAccountTransition.fingerprint(accountID)), \(transition.logDescription)"
            )
            switch transition {
            case .firstAdoption, .unchanged:
                break
            case .changed:
                lockOutForAccountChange()
                return
            }
            preferences.accountID = accountID

            var config = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: decodeEngineState(),
                delegate: self
            )
            config.automaticallySync = true
            let engine = CKSyncEngine(config)
            self.engine = engine
            self.database = container.privateCloudDatabase
            // Only a device that has not adopted yet creates the zone on start. Queued on every start,
            // it raced the fetch that would have told this device another one had deleted the zone,
            // and recreated it: "Delete iCloud Data" came undone whenever any other device woke up.
            if !preferences.adoptionCompleted {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            }
            // Healthy only once there is something to be healthy about: before the adoption fetch
            // this device has not seen the zone, and "Active" there reads as "nothing in iCloud".
            if preferences.adoptionCompleted { settleActive() }

            // Replay anything queued while the engine was unavailable (signed out,
            // failed start, or before this start() completed) so it isn't lost.
            stash = preferences.drainPendingChanges()
            recentLocalDeletes.formUnion(stash.deletes)
            // Back into the outbox as they go to the engine: the drain emptied it, and a delete that
            // lived in engine memory only was lost to a kill before the next state event.
            for name in stash.deletes {
                addPendingDelete(recordName: name)
            }
            for name in stash.saves {
                addPendingSave(recordName: name)
            }

            if !preferences.adoptionCompleted {
                try await engine.fetchChanges()
                // A teardown during the fetch (an account notification, a sign-out) means its events
                // were dropped as a stale engine's. Adopting anyway stamped and uploaded this device's
                // untouched defaults over every other device, parental controls included.
                guard observationGeneration == generation, self.engine === engine else {
                    LogTap.shared.note("[CloudSync] start superseded during the adoption fetch, not adopting")
                    return
                }
                completeAdoption()
                settleActive()
            }
            await afterEngineStart(engine)
        } catch {
            // A start that was superseded while it waited must not overwrite the newer one's status
            // or drop its engine.
            guard observationGeneration == generation else {
                stash.saves.forEach(preferences.stashPendingSave)
                stash.deletes.forEach(preferences.stashPendingDelete)
                return
            }
            status = .error(CloudSyncRecovery.describe(error))
            LogTap.shared.note("[CloudSync] start failed: \(error)")
            handleFetchFailure(error)
            // A failed adoption fetch must not lose the drained stash: put it back
            // (both stash methods are idempotent) so a relaunch still replays it.
            stash.saves.forEach(preferences.stashPendingSave)
            stash.deletes.forEach(preferences.stashPendingDelete)
            recentLocalDeletes.subtract(stash.deletes)
            // A failed adoption fetch must not leave a half-started engine syncing
            // in cloud-wins posture forever; drop it so the next start() retries cleanly.
            if !preferences.adoptionCompleted { engine = nil }
        }
    }

    /// Uploads everything local that adoption's fetch did not already reconcile,
    /// then latches the adoption flag. Internal for tests.
    func completeAdoption() {
        for server in dependencies.listKnownServers() {
            stampServer(serverID: server.id)
        }
        for key in CloudSyncStoreKey.allCases {
            // Only upload stores the cloud did not already win at adoption.
            if preferences.localStamp(for: CloudSyncRecordName.settings(key)) == nil {
                markSettingsDirty(key)
            }
        }
        if preferences.localStamp(for: CloudSyncRecordName.securitySingleton) == nil,
           dependencies.isGuardianPINSet() {
            markSecurityDirty()
        }
        // Profile records: every kind that is a real edit or came from the cloud, and that the
        // adoption fetch did not already settle. Provisional copies stay local.
        let registry = dependencies.profileSettings
        for key in registry.knownProfiles {
            for kind in ProfileRecordKind.allCases
            where !registry.isProvisional(key, kind)
                && preferences.localStamp(for: CloudSyncRecordName.profile(kind, key)) == nil {
                markProfileDirty(kind, key)
            }
        }
        preferences.adoptionCompleted = true
        LogTap.shared.note("[CloudSync] adoption complete")
    }

    /// Blocks (yielding) until the first adoption fetch has completed, a terminal
    /// state makes waiting pointless, or the timeout expires. Used to gate the
    /// fresh-install launch so synced servers surface before the discovery screen.
    func waitForInitialSync(timeout: TimeInterval) async {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        func exit(_ reason: String) {
            let waited = String(format: "%.1f", Date().timeIntervalSince(started))
            LogTap.shared.note("[CloudSync] initial sync wait ended after \(waited) s: \(reason)")
        }
        while Date() < deadline {
            // Cancelled callers must exit immediately: a cancelled Task.sleep throws
            // right away (swallowed by try?), so continuing would busy-spin the
            // MainActor until the deadline.
            if Task.isCancelled { return }
            if preferences.adoptionCompleted { return exit("adoption complete") }
            switch status {
            case .noAccount, .disabled, .accountChanged, .error: return exit("status \(status)")
            case .active, .syncing: break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        exit("timeout, adoption still pending")
    }

    func fetchNow() async {
        // A start still in flight owns the adoption fetch. Fetching beside it on the engine it has
        // already installed ran a second fetch against a zone this device had not adopted yet.
        if engine != nil, startInFlight { await startTask?.value }
        if engine == nil {
            // A failed or skipped start (offline launch, signed-out account) must be
            // retryable in-session; foregrounding is the natural retry point.
            guard preferences.isEnabled else { return }
            if !startInFlight { start() }
            // The engine only exists after two CloudKit round trips (account status,
            // user record), so a cold-launch foreground always arrives before it.
            // Awaiting the start is what makes that first fetch happen at all:
            // startEngine itself only fetches while adoption is still pending, and
            // without a fetch here a device that finished adoption would receive
            // remote changes solely from silent pushes.
            await startTask?.value
        }
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            // One line per fetch: a fetch that brings nothing logs nothing else, which reads the
            // same as a fetch that never ran.
            LogTap.shared.note("[CloudSync] fetch done")
            // A fetch that changed nothing posts no event, so an earlier fetch failure would
            // otherwise stay on the status row. A latched upload rejection survives this.
            if case .error = status { settleActive() }
        } catch {
            LogTap.shared.note("[CloudSync] fetch failed: \(error)")
            handleFetchFailure(error)
        }
    }

    /// A failure that is not recovered here has to reach the status: a manual load reads its
    /// outcome from there, and a silent failure used to come back as "nothing in iCloud".
    private func handleFetchFailure(_ error: Error) {
        guard let ckError = error as? CKError else {
            status = .error(CloudSyncRecovery.describe(error))
            return
        }
        switch CloudSyncRecovery.fetchAction(for: ckError) {
        case .resyncZone:
            resyncZoneFromScratch(reason: "change token expired")
        case .report:
            status = .error(CloudSyncRecovery.describe(error))
        }
    }

    /// Local knowledge of the zone is provably out of step with the server: either the change
    /// token no longer matches its history, or a save came back rejected as an insert of a record
    /// that already exists. Both mean the cached record identities are worthless, and nothing in
    /// the engine ever relearns them, so the zone has to be fetched from scratch.
    ///
    /// Deliberately NOT an adoption reset. The LWW stamps survive, so the fetch applies normally
    /// and `applyRemoteRecord` re-queues everything that is locally newer, with the identities it
    /// just learned. A manual push therefore still wins against the cloud copy it was meant to
    /// overwrite instead of being silently reverted by its own recovery.
    private func resyncZoneFromScratch(reason: String, afterRejectedSave: Bool = false) {
        guard preferences.isEnabled, resyncTask == nil else { return }
        guard resyncCount < Self.maxResyncsPerSession else {
            // Said to leave "the error" up, but nothing had set one: the row read healthy while the
            // record was never going to land. Latched only for a save the server keeps refusing; an
            // expired change token is a download problem, and the next good fetch may clear it.
            if afterRejectedSave {
                latchFailure(Self.rejectedMessage)
            } else {
                status = .error(CloudSyncRecovery.describe(CKError(.changeTokenExpired)))
            }
            LogTap.shared.note("[CloudSync] resync limit reached, sync error shown: \(reason)")
            return
        }
        resyncCount += 1
        LogTap.shared.note("[CloudSync] resyncing zone from scratch (\(reason))")

        // Queued changes live in the engine's in-memory state, which the restart below drops.
        // Stash them so startEngine's drain replays them onto the fresh engine.
        if let engine {
            for change in engine.state.pendingRecordZoneChanges {
                switch change {
                case .saveRecord(let recordID): preferences.stashPendingSave(recordID.recordName)
                case .deleteRecord(let recordID): preferences.stashPendingDelete(recordID.recordName)
                @unknown default: break
                }
            }
        }
        preferences.forgetAllSystemFields()
        preferences.engineState = nil
        status = .syncing

        resyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.resyncTask = nil }
            self.teardownEngine()
            self.start()
            await self.startTask?.value
            await self.fetchNow()
            guard let engine = self.engine else { return }
            // The fetch relearned the identities and re-queued whatever is locally newer; flush
            // it now rather than leaving the user's push to the automatic scheduler.
            try? await engine.sendChanges()
            if case .syncing = self.status {
                self.settleActive()
            }
        }
    }

    /// Manual load from the discovery screen. A full logout leaves sync disabled,
    /// so this has to re-enable it (the tap is the explicit user consent) before any
    /// fetch can land, then report what actually happened rather than assuming an
    /// empty zone. Deliberately unbounded: CloudKit's own timeouts surface as a real
    /// error, which beats calling a slow network "no data in iCloud".
    func loadFromCloud() async -> CloudSyncLoadOutcome {
        if !preferences.isEnabled { setEnabled(true) }
        // Same in-flight signal the manual push uses, so the settings status row shows
        // the tap did something. Only over a healthy state: a real error or a missing
        // account must stay visible.
        if case .active = status { status = .syncing }
        await fetchNow()
        // A fetch that changed nothing never posts .fetchedRecordZoneChanges, so settle
        // the transient state here instead of leaving it stuck on "Syncing…".
        if case .syncing = status, preferences.adoptionCompleted { settleActive() }
        let outcome = CloudSyncLoadOutcome.resolve(
            status: status,
            hasServers: !dependencies.listKnownServers().isEmpty,
            adoptionCompleted: preferences.adoptionCompleted
        )
        LogTap.shared.note("[CloudSync] load from iCloud: \(outcome), status \(status), adoption \(preferences.adoptionCompleted ? "complete" : "pending")")
        return outcome
    }

    // MARK: Dirty marking (called from DependencyContainer mutation hooks)

    /// From the container's mutation hooks: queued only when the record's content actually changed.
    func markServerDirty(serverID: String) {
        guard preferences.tracksLocalEdits else { return }
        let snapshot = dependencies.collectServerPayload(serverID: serverID, stamp: .distantPast)
        guard snapshot == nil || snapshot != lastServerSnapshot[serverID] else { return }
        lastServerSnapshot[serverID] = snapshot
        stampServer(serverID: serverID)
    }

    /// Unconditional: adoption has to publish every server whatever it held before.
    private func stampServer(serverID: String) {
        guard preferences.tracksLocalEdits else { return }
        let name = CloudSyncRecordName.server(id: serverID)
        preferences.setLocalStamp(preferences.nextStamp(), for: name)
        addPendingSave(recordName: name)
    }

    func markServerDeleted(serverID: String) {
        guard preferences.tracksLocalEdits else { return }
        let name = CloudSyncRecordName.server(id: serverID)
        preferences.removeRecordCaches(for: name)
        // Also with a live engine, not just on the stashed path: a fetch landing between the
        // queued delete and its confirmation would otherwise re-adopt the record we just removed.
        recentLocalDeletes.insert(name)
        addPendingDelete(recordName: name)
    }

    func markSettingsDirty(_ key: CloudSyncStoreKey) {
        guard preferences.tracksLocalEdits else { return }
        let name = CloudSyncRecordName.settings(key)
        preferences.setLocalStamp(preferences.nextStamp(), for: name)
        addPendingSave(recordName: name)
    }

    /// Internal for tests.
    func markProfileDirty(_ kind: ProfileRecordKind, _ key: ProfileKey) {
        guard preferences.tracksLocalEdits else { return }
        let name = CloudSyncRecordName.profile(kind, key)
        preferences.setLocalStamp(preferences.nextStamp(), for: name)
        addPendingSave(recordName: name)
    }

    func markSecurityDirty() {
        guard preferences.tracksLocalEdits else { return }
        preferences.setLocalStamp(preferences.nextStamp(), for: CloudSyncRecordName.securitySingleton)
        addPendingSave(recordName: CloudSyncRecordName.securitySingleton)
    }

    func markSecurityDeleted() {
        guard preferences.tracksLocalEdits else { return }
        let name = CloudSyncRecordName.securitySingleton
        preferences.removeRecordCaches(for: name)
        recentLocalDeletes.insert(name)
        addPendingDelete(recordName: name)
    }

    /// Manual push: re-stamp every settings store so THIS device wins LWW
    /// everywhere until the next change on any device. Settings only, never
    /// server records (those would clobber newer remote credential changes).
    func pushLocalSettingsToAllDevices() {
        guard preferences.isEnabled else {
            LogTap.shared.note("[CloudSync] manual settings push skipped, sync is off")
            return
        }
        for key in CloudSyncStoreKey.allCases {
            lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
            markSettingsDirty(key)
        }
        let registry = dependencies.profileSettings
        // The active profile's copies are the settings the viewer is looking at and asked to push; a
        // device that migrated and was never edited since has nothing else. Other profiles' copies
        // were never seen here and stay local.
        if let active = registry.activeKey() {
            for kind in ProfileRecordKind.allCases { registry.claim(active, kind) }
        }
        var queued = 0
        var provisional = 0
        for key in registry.knownProfiles {
            for kind in ProfileRecordKind.allCases {
                guard !registry.isProvisional(key, kind) else { provisional += 1; continue }
                lastProfileSnapshot[CloudSyncRecordName.profile(kind, key)] =
                    dependencies.collectProfilePayload(kind, key: key, stamp: .distantPast)
                markProfileDirty(kind, key)
                queued += 1
            }
        }
        LogTap.shared.note("[CloudSync] manual settings push queued: \(CloudSyncStoreKey.allCases.count) settings, \(queued) profile record(s), \(provisional) left local as copies")
        guard let engine else { return }
        // Force the upload now instead of waiting for the automatic scheduler, so a
        // manual push lands immediately and the status timestamp reflects it promptly.
        status = .syncing
        Task { @MainActor [weak self] in
            do {
                try await engine.sendChanges()
            } catch {
                guard let self else { return }
                LogTap.shared.note("[CloudSync] manual push send failed: \(error)")
                self.status = .error(CloudSyncRecovery.describe(error))
                self.handlePartialSendFailure(error, syncEngine: engine)
                return
            }
            // The .sentRecordZoneChanges event already advanced status to .active when
            // records were saved; only settle a push that sent nothing back itself.
            guard let self else { return }
            if case .syncing = self.status {
                self.settleActive()
            }
        }
    }

    func deleteCloudDataAndDisable() async {
        guard preferences.isEnabled else {
            await deleteZoneWhileOff()
            return
        }
        if engine == nil {
            if !startInFlight { start() }
            await startTask?.value
        }
        guard let engine else {
            // Nothing reached iCloud, so nothing may be wiped here either: the zone is still there,
            // and reporting success is how its data came back on the next enable. The status the
            // failed start left (no account, or CloudKit's error) says why.
            preferences.isEnabled = false
            teardownEngine()
            if case .active = status { status = .disabled }
            observeWhileOff()
            LogTap.shared.note("[CloudSync] cloud data delete not sent, no engine (status \(status))")
            return
        }
        var failure: Error?
        deletingZone = true
        zoneDeleteFailure = nil
        // Pending saves would go out in the same send, fail against the zone being deleted, and are
        // pointless anyway: everything they would write is about to be removed.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        do {
            engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
            try await engine.sendChanges()
        } catch {
            failure = error
        }
        deletingZone = false
        // A zone delete the server refused is reported per zone and does not necessarily throw.
        if failure == nil, let refused = zoneDeleteFailure { failure = refused }
        preferences.isEnabled = false
        if let failure {
            // The zone survived. Wiping the local bookkeeping now is precisely how the identities
            // and the server drift apart, so keep it and say the deletion did not happen instead
            // of reporting success and leaving an unsaveable zone behind.
            teardownEngine()
            status = .error(CloudSyncRecovery.describe(failure))
            observeWhileOff()
            LogTap.shared.note("[CloudSync] cloud data delete failed, local state kept: \(failure)")
            return
        }
        finishCloudDataDeletion()
        LogTap.shared.note("[CloudSync] cloud data deleted, sync disabled")
    }

    /// The delete asked for while sync is off. Starting the engine for it would first run the
    /// adoption the zone is about to lose, uploads included, so the zone goes directly; the
    /// confirmation is the consent. A failure has to reach the status row: "Off" alone read as done.
    private func deleteZoneWhileOff() async {
        guard Self.isEntitledForCloudKit else {
            status = .disabled
            return
        }
        status = .syncing
        let container = CKContainer(identifier: Self.containerID)
        do {
            guard try await container.accountStatus() == .available else {
                status = .noAccount
                LogTap.shared.note("[CloudSync] cloud data delete not sent, no iCloud account")
                return
            }
            do {
                _ = try await container.privateCloudDatabase.deleteRecordZone(withID: Self.zoneID)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                LogTap.shared.note("[CloudSync] cloud data delete: no zone in iCloud")
            }
        } catch {
            status = .error(CloudSyncRecovery.describe(error))
            LogTap.shared.note("[CloudSync] cloud data delete failed while sync is off: \(error)")
            return
        }
        // Switched on while the delete was out: that start owns the bookkeeping now.
        guard !preferences.isEnabled else { return }
        finishCloudDataDeletion()
        LogTap.shared.note("[CloudSync] cloud data deleted while sync was off")
    }

    private func finishCloudDataDeletion() {
        preferences.resetForCloudDataDeletion()
        preferences.accountChangeLocked = false
        teardownEngine()
        statusLatch.clear()
        status = .disabled
    }

    /// Full local logout: stop syncing, keep cloud data intact (no multi-device
    /// wipe from one logout). Re-enabling later re-adopts from the cloud.
    func handleFullLogout() {
        preferences.isEnabled = false
        preferences.accountChangeLocked = false
        preferences.resetForCloudDataDeletion()
        teardownEngine()
        statusLatch.clear()
        status = .disabled
    }

    /// A factory reset wiped the defaults domain this bookkeeping lives in, the off switch Log Out
    /// had just written included, and the next launch read the missing key as the factory default:
    /// on, with no adoption behind it, so it re-adopted the whole zone and signed the old household
    /// back in. Call it after the wipe. Sync stays off until someone turns it on again, and the
    /// account and every record identity go too, so that turn-on is a deliberate first adoption.
    func handleFactoryReset() {
        teardownEngine()
        preferences.resetForAccountChange()
        preferences.isEnabled = false
        preferences.accountChangeLocked = false
        statusLatch.clear()
        status = .disabled
    }

    // MARK: Observation of local changes

    private func observeAccountChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.preferences.isEnabled else { return }
                LogTap.shared.note("[CloudSync] iCloud account changed, restarting engine")
                self.teardownEngine()
                self.start()
            }
        }
        observers.append(observer)
    }

    private func observeHomeConfigChanges() {
        for name in [Notification.Name.homeConfigDidChange, .librarySortDidChange] {
            observeServerRecordTrigger(name)
        }
    }

    /// Marks the active server dirty when a per-server preference changed locally.
    private func observeServerRecordTrigger(_ name: Notification.Name) {
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            // Synchronous check: the apply paths post this while isApplyingCloudChanges
            // is still true; deferring into a Task would read the flag after its
            // defer-reset and echo every cloud-applied change back as an upload.
            MainActor.assumeIsolated {
                guard let self, !self.dependencies.isApplyingCloudChanges else { return }
                if let serverID = self.dependencies.activeServer?.id {
                    self.markServerDirty(serverID: serverID)
                }
            }
        }
        observers.append(observer)
    }

    /// The observers fire on more than edits: collecting goes through the active profile, so a
    /// session restore fires every one of them. Against an empty snapshot each read as a change and
    /// went up with a fresh stamp on every launch, which let a device's stale copy outrank an edit
    /// another device had made while it was closed. Internal for tests.
    func seedSettingsSnapshots() {
        for key in CloudSyncStoreKey.allCases where !key.isProfileBacked {
            lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
        }
        for server in dependencies.listKnownServers() {
            lastServerSnapshot[server.id] = dependencies.collectServerPayload(serverID: server.id, stamp: .distantPast)
        }
    }

    private func observeSettingsStores() {
        // The two profile-backed records are uploaded from the registry's write hooks (see init).
        for key in CloudSyncStoreKey.allCases where !key.isProfileBacked { armObservation(for: key) }
    }

    private func armObservation(for key: CloudSyncStoreKey) {
        let generation = observationGeneration
        withObservationTracking {
            // Touch every synced property so any change re-arms us.
            _ = dependencies.collectSettingsPayload(key, stamp: .distantPast)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.scheduleSettingsUpload(key)
                self.armObservation(for: key)
            }
        }
    }

    private func scheduleSettingsUpload(_ key: CloudSyncStoreKey, profile: ProfileKey? = nil) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.uploadSettingsIfChanged(key, profile: profile)
        }
    }

    /// Internal for tests.
    func uploadSettingsIfChanged(_ key: CloudSyncStoreKey, profile: ProfileKey? = nil) {
        guard preferences.tracksLocalEdits, !dependencies.isApplyingCloudChanges else { return }
        let snapshot = key.isProfileBacked
            ? dependencies.collectSettingsPayload(key, stamp: .distantPast, profile: profile)
            : dependencies.collectSettingsPayload(key, stamp: .distantPast)
        if lastSettingsSnapshot[key] == snapshot { return }
        lastSettingsSnapshot[key] = snapshot
        markSettingsDirty(key)
    }

    /// Internal for tests. Takes the profile the edit was made in, never the active one.
    func uploadProfileIfChanged(_ kind: ProfileRecordKind, _ key: ProfileKey) {
        guard preferences.tracksLocalEdits, !dependencies.isApplyingCloudChanges else { return }
        guard !dependencies.profileSettings.isProvisional(key, kind) else {
            LogTap.shared.note("[CloudSync] \(key.fingerprint) \(kind.rawValue) is a local copy, not uploaded")
            return
        }
        guard let snapshot = dependencies.collectProfilePayload(kind, key: key, stamp: .distantPast)
        else { return }
        let name = CloudSyncRecordName.profile(kind, key)
        if lastProfileSnapshot[name] == snapshot { return }
        lastProfileSnapshot[name] = snapshot
        markProfileDirty(kind, key)
    }

    // MARK: Record building / applying

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: Self.zoneID)
    }

    private func recordType(forRecordName name: String) -> CKRecord.RecordType {
        CloudSyncRecordName.recordType(forRecordName: name)
    }

    /// Every save is also written to the persistent outbox and leaves it only once CloudKit confirms
    /// it: the engine persists its own queue through a later state event, and an app killed before
    /// that event lost the save for good.
    private func addPendingSave(recordName: String) {
        preferences.stashPendingSave(recordName)
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(recordName))])
    }

    /// Same outbox for deletes. With a live engine they used to live in its memory only until the
    /// next state event, and a removed Guardian PIN has no tombstone that would carry it otherwise.
    private func addPendingDelete(recordName: String) {
        preferences.stashPendingDelete(recordName)
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(recordName))])
    }

    private func collectPayloadData(recordName: String) -> Data? {
        let stamp = preferences.localStamp(for: recordName) ?? preferences.nextStamp()
        inFlightStamps[recordName] = stamp
        guard let encoded = encodeLocalPayload(recordName: recordName, stamp: stamp) else { return nil }
        // Uploads stay additive across app versions: whatever a newer build wrote into this record
        // and this one cannot decode rides along instead of being dropped, which last-writer-wins
        // would otherwise hand to every newer device as an authoritative reset.
        return CloudSyncForwardCompat.merged(local: encoded, carrying: preferences.carriedFields(for: recordName))
    }

    private func encodeLocalPayload(recordName: String, stamp: Date) -> Data? {
        if let serverID = CloudSyncRecordName.serverID(fromRecordName: recordName) {
            guard let payload = dependencies.collectServerPayload(serverID: serverID, stamp: stamp) else { return nil }
            return try? JSONEncoder().encode(payload)
        }
        if let key = CloudSyncRecordName.storeKey(fromRecordName: recordName) {
            return try? dependencies.collectSettingsPayload(key, stamp: stamp).encoded()
        }
        if case let (kind, key)? = CloudSyncRecordName.profileRecord(fromRecordName: recordName) {
            return try? dependencies.collectProfilePayload(kind, key: key, stamp: stamp)?.encoded()
        }
        guard let payload = dependencies.collectSecurityPayload(stamp: stamp) else { return nil }
        return try? JSONEncoder().encode(payload)
    }

    /// Remember the fields of a remote payload this build cannot write, so the next upload from
    /// here carries them instead of resetting them for every device that does understand them.
    private func noteCarriedFields(remote: Data, recordName: String) {
        guard let known = knownFields(forRecordName: recordName) else { return }
        preferences.setCarriedFields(
            CloudSyncForwardCompat.unknownFields(remote: remote, known: known),
            for: recordName
        )
    }

    private func knownFields(forRecordName recordName: String) -> Set<String>? {
        if let serverID = CloudSyncRecordName.serverID(fromRecordName: recordName) {
            return dependencies.collectServerPayload(serverID: serverID, stamp: .distantPast)
                .map(CloudSyncForwardCompat.storedPropertyNames(of:))
        }
        if let key = CloudSyncRecordName.storeKey(fromRecordName: recordName) {
            return dependencies.collectSettingsPayload(key, stamp: .distantPast).knownFields
        }
        if case let (kind, key)? = CloudSyncRecordName.profileRecord(fromRecordName: recordName) {
            return dependencies.collectProfilePayload(kind, key: key, stamp: .distantPast)?.knownFields
        }
        return dependencies.collectSecurityPayload(stamp: .distantPast)
            .map(CloudSyncForwardCompat.storedPropertyNames(of:))
    }

    private func buildRecord(recordName: String) -> CKRecord? {
        guard let payloadData = collectPayloadData(recordName: recordName) else {
            // Nothing local anymore (e.g. server removed while queued): drop the save.
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID(recordName))])
            preferences.unstashPendingSave(recordName)
            return nil
        }
        let record: CKRecord
        if let archived = preferences.systemFields(for: recordName),
           let restored = Self.decodeSystemFields(archived) {
            record = restored
        } else {
            record = CKRecord(recordType: recordType(forRecordName: recordName), recordID: recordID(recordName))
        }
        record.encryptedValues[Self.payloadKey] = payloadData
        return record
    }

    private func applyRemoteRecord(_ record: CKRecord) {
        // A record we are about to delete (or have queued a delete for while the
        // engine was unavailable) must not resurrect locally via the adoption fetch.
        guard !recentLocalDeletes.contains(record.recordID.recordName) else { return }
        let name = record.recordID.recordName
        guard let data = record.encryptedValues[Self.payloadKey] as? Data else {
            // Reachable when CloudKit cannot decrypt the field for this device (no
            // iCloud Keychain, so no zone key). Silence here looks exactly like an
            // empty zone from the outside, so say it.
            noteSkipped(name, reason: "no readable payload")
            return
        }
        preferences.setSystemFields(Self.encodeSystemFields(record), for: name)
        // Deferred: a server record adopted for the first time is not in the local store until the
        // branches below have applied it, and there is no known-field set to diff against before
        // that. The union branches return early, so this cannot be a straight-line call.
        defer { noteCarriedFields(remote: data, recordName: name) }
        let adopting = !preferences.adoptionCompleted
        // Settings, profile and security records: first adoption and a manual pull take the cloud.
        let cloudWins = adopting || forcingCloudWins

        if let serverID = CloudSyncRecordName.serverID(fromRecordName: name) {
            guard let cloud = decodeOrSkip(name, "server", { try JSONDecoder().decode(ServerSyncPayload.self, from: data) }) else {
                return
            }
            preferences.clearSkippedRecord(name)
            preferences.noteRemoteStamp(cloud.updatedAt)
            if adopting, let local = dependencies.collectServerPayload(serverID: serverID, stamp: .distantPast) {
                let merged = CloudSyncMerge.adoptServerPayload(local: local, cloud: cloud, stamp: preferences.nextStamp())
                preservingPendingAuthEdit { dependencies.applyServerPayload(merged) }
                lastServerSnapshot[serverID] = dependencies.collectServerPayload(serverID: serverID, stamp: .distantPast)
                preferences.setLocalStamp(merged.updatedAt, for: name)
                if merged != cloud { addPendingSave(recordName: name) }
            } else {
                let localStamp = preferences.localStamp(for: name) ?? .distantPast
                if CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) || adopting {
                    preservingPendingAuthEdit { dependencies.applyServerPayload(cloud) }
                    lastServerSnapshot[serverID] = dependencies.collectServerPayload(serverID: serverID, stamp: .distantPast)
                    preferences.setLocalStamp(cloud.updatedAt, for: name)
                } else if CloudSyncMerge.remoteWins(localUpdatedAt: cloud.updatedAt, remoteUpdatedAt: localStamp) {
                    addPendingSave(recordName: name)
                }
            }
        } else if case let (kind, profile)? = CloudSyncRecordName.profileRecord(fromRecordName: name) {
            guard let cloud = decodeOrSkip(name, "profile", { try ProfileSyncPayload.decode(data, kind: kind) }) else {
                return
            }
            preferences.clearSkippedRecord(name)
            preferences.noteRemoteStamp(cloud.updatedAt)
            let localStamp = preferences.localStamp(for: name) ?? .distantPast
            // An unstamped local profile is a provisional copy or was never uploaded, and loses to
            // any record, which is exactly the rule a seeded copy needs.
            if cloudWins || CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) {
                dependencies.applyProfilePayload(cloud, key: profile)
                lastProfileSnapshot[name] = dependencies.collectProfilePayload(kind, key: profile, stamp: .distantPast)
                preferences.setLocalStamp(cloud.updatedAt, for: name)
            } else {
                Self.noteLocalKept(name, local: localStamp, cloud: cloud.updatedAt)
                if CloudSyncMerge.remoteWins(localUpdatedAt: cloud.updatedAt, remoteUpdatedAt: localStamp) {
                    addPendingSave(recordName: name)
                }
            }
        } else if let key = CloudSyncRecordName.storeKey(fromRecordName: name) {
            guard let cloud = decodeOrSkip(name, "settings", { try SettingsSyncPayload.decode(data, key: key) }) else {
                return
            }
            preferences.clearSkippedRecord(name)
            preferences.noteRemoteStamp(cloud.updatedAt)
            // Sodalite#46: track memory is per entry, not one blob. Last-writer-wins would
            // drop every title the other device recorded, so union instead, adoption
            // included, and re-upload when the merge produced more than the cloud had.
            if case .trackMemory(let cloudMemory) = cloud {
                guard case .trackMemory(let localMemory) = dependencies.collectSettingsPayload(
                    key, stamp: preferences.localStamp(for: name) ?? .distantPast
                ) else { return }
                let merged = CloudSyncMerge.unionTrackMemory(local: localMemory, cloud: cloudMemory)
                dependencies.applySettingsPayload(.trackMemory(merged))
                lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
                preferences.setLocalStamp(merged.updatedAt, for: name)
                if merged.entries != cloudMemory.entries { addPendingSave(recordName: name) }
                return
            }
            // Sodalite#50: reveals are per entry like track memory, so union instead of
            // last-writer-wins, adoption included.
            if case .spoilerReveals(let cloudReveals) = cloud {
                guard case .spoilerReveals(let localReveals) = dependencies.collectSettingsPayload(
                    key, stamp: preferences.localStamp(for: name) ?? .distantPast
                ) else { return }
                let merged = CloudSyncMerge.unionSpoilerReveals(local: localReveals, cloud: cloudReveals)
                dependencies.applySettingsPayload(.spoilerReveals(merged))
                lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
                preferences.setLocalStamp(merged.updatedAt, for: name)
                if merged.entries != cloudReveals.entries { addPendingSave(recordName: name) }
                return
            }
            // Sodalite#50 follow-up: series rules are per entry as well, and "never veil this show"
            // cannot be expressed by a union, so merge per key with the tombstone in the running.
            if case .spoilerSeriesRules(let cloudRules) = cloud {
                guard case .spoilerSeriesRules(let localRules) = dependencies.collectSettingsPayload(
                    key, stamp: preferences.localStamp(for: name) ?? .distantPast
                ) else { return }
                let merged = CloudSyncMerge.mergeSpoilerSeriesRules(local: localRules, cloud: cloudRules)
                dependencies.applySettingsPayload(.spoilerSeriesRules(merged))
                lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
                preferences.setLocalStamp(merged.updatedAt, for: name)
                if merged.entries != cloudRules.entries { addPendingSave(recordName: name) }
                return
            }
            // Server removals union like the maps above, so they are taken even when the record as a
            // whole loses last-writer-wins. Without this a device that happened to write some other
            // auth setting more recently would discard the payload entire and never learn that a
            // server was removed, leaving it standing there for good. The rest of the auth payload
            // still obeys LWW below; applying the map twice is idempotent.
            if case .auth(let auth) = cloud, let removals = auth.forgottenServers {
                dependencies.applyForgottenServers(removals)
                lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
            }
            let localStamp = preferences.localStamp(for: name) ?? .distantPast
            if cloudWins || CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) {
                dependencies.applySettingsPayload(cloud)
                lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
                preferences.setLocalStamp(cloud.updatedAt, for: name)
            } else {
                Self.noteLocalKept(name, local: localStamp, cloud: cloud.updatedAt)
                if CloudSyncMerge.remoteWins(localUpdatedAt: cloud.updatedAt, remoteUpdatedAt: localStamp) {
                    addPendingSave(recordName: name)
                }
            }
        } else if name == CloudSyncRecordName.securitySingleton {
            guard let cloud = decodeOrSkip(name, "security", { try JSONDecoder().decode(SecuritySyncPayload.self, from: data) }) else {
                return
            }
            preferences.clearSkippedRecord(name)
            preferences.noteRemoteStamp(cloud.updatedAt)
            let localStamp = preferences.localStamp(for: name) ?? .distantPast
            if adopting || CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) {
                dependencies.applySecurityPayload(cloud)
                preferences.setLocalStamp(cloud.updatedAt, for: name)
            } else if CloudSyncMerge.remoteWins(localUpdatedAt: cloud.updatedAt, remoteUpdatedAt: localStamp) {
                addPendingSave(recordName: name)
            }
        }
    }

    /// A fetched record that loses last-writer-wins changes nothing here, so without this line a
    /// device that keeps its own copy looks exactly like one that never received the record.
    private static func noteLocalKept(_ name: String, local: Date, cloud: Date) {
        let verdict = local == cloud ? "tie" : "local newer, re-uploading"
        LogTap.shared.note(
            "[CloudSync] kept local \(name) (\(verdict)): local \(local.timeIntervalSince1970) cloud \(cloud.timeIntervalSince1970)"
        )
    }

    /// A server record can move the default-server pin, which lives in the auth store, so the auth
    /// snapshot is re-baselined or the debounced observer reads the apply as a local edit two seconds
    /// later and uploads it back. Only when nothing was pending, though: an auth edit still inside
    /// its debounce is already in the store, and re-baselining over it meant it never went up.
    private func preservingPendingAuthEdit(_ apply: () -> Void) {
        let before = dependencies.collectSettingsPayload(.auth, stamp: .distantPast)
        let nothingPending = lastSettingsSnapshot[.auth] == before
        apply()
        if nothingPending {
            lastSettingsSnapshot[.auth] = dependencies.collectSettingsPayload(.auth, stamp: .distantPast)
        }
    }

    private func applyRemoteDeletion(recordName: String) {
        preferences.removeRecordCaches(for: recordName)
        if let serverID = CloudSyncRecordName.serverID(fromRecordName: recordName) {
            preservingPendingAuthEdit { dependencies.applyRemoteServerDeletion(serverID: serverID) }
        } else if recordName == CloudSyncRecordName.securitySingleton {
            dependencies.applyRemoteSecurityDeletion()
        }
        // Settings and profile records are never deleted remotely; ignore anything else.
    }

    // MARK: System field + engine state codecs

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    private func decodeEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = preferences.engineState else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    // MARK: Direct reads

    /// Manual pull: the settings and profile records as iCloud holds them now, applied cloud-wins.
    /// A delta fetch cannot do this, it only delivers what changed since this device last asked, so
    /// a record it already had (and lost to a local stamp) never came again. Server records keep
    /// their merge, they carry credentials a pull must not roll back.
    func pullSettingsFromCloud() async {
        await fetchNow()
        guard let database, engine != nil else {
            LogTap.shared.note("[CloudSync] pull skipped, no engine (status \(status))")
            return
        }
        status = .syncing
        do {
            let records = try await Self.fetchWholeZone(database)
                .filter { CloudSyncRecordName.serverID(fromRecordName: $0.recordID.recordName) == nil }
                .filter { $0.recordID.recordName != CloudSyncRecordName.securitySingleton }
                .sorted { Self.applyOrder($0.recordID.recordName) < Self.applyOrder($1.recordID.recordName) }
            forcingCloudWins = true
            for record in records { applyRemoteRecord(record) }
            forcingCloudWins = false
            LogTap.shared.note("[CloudSync] pull applied \(records.count) record(s): \(Self.summary(records.map(\.recordID.recordName)))")
            preferences.lastSyncAt = Date()
            settleActive()
            NotificationCenter.default.post(name: .cloudSyncDidApplyChanges, object: nil)
        } catch let error as CKError where error.code == .zoneNotFound {
            LogTap.shared.note("[CloudSync] pull found no Sodalite data in iCloud")
            settleActive()
        } catch {
            forcingCloudWins = false
            LogTap.shared.note("[CloudSync] pull failed: \(error)")
            status = .error(CloudSyncRecovery.describe(error))
        }
    }

    private static func fetchWholeZone(_ database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let batch = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for result in batch.modificationResultsByID.values {
                if case .success(let modification) = result { records.append(modification.record) }
            }
            token = batch.changeToken
            moreComing = batch.moreComing
        }
        return records
    }

    /// Work that needs a live engine and an adopted zone, once per start.
    private func afterEngineStart(_ engine: CKSyncEngine) async {
        await refetchSkippedRecords()
        await claimUnclaimedMigrationSeeds()
    }

    /// A record this device could not read was lost for good: the change token moves past it and
    /// no delta fetch delivers it again. Asking for it by name on the next start is the retry.
    private func refetchSkippedRecords() async {
        let names = preferences.skippedRecords
        guard !names.isEmpty, let database else { return }
        do {
            let results = try await database.records(for: names.map(recordID))
            var recovered = 0
            var abandoned = 0
            for (id, result) in results {
                switch result {
                case .success(let record):
                    applyRemoteRecord(record)
                    if !preferences.skippedRecords.contains(id.recordName) {
                        recovered += 1
                    } else if preferences.noteSkippedRetryFailed(id.recordName) {
                        abandoned += 1
                    }
                case .failure(let error as CKError) where error.code == .unknownItem:
                    preferences.clearSkippedRecord(id.recordName)
                case .failure:
                    break
                }
            }
            LogTap.shared.note("[CloudSync] retried \(names.count) skipped record(s), \(recovered) now readable, \(abandoned) given up after \(CloudSyncPreferences.maxSkippedRetries) starts")
        } catch {
            LogTap.shared.note("[CloudSync] skipped-record retry failed: \(error)")
        }
    }

    /// The one-time migration to per-profile settings seeded every profile from the values this
    /// device had until then, and a seed only ever went up after an edit. A device nobody touched
    /// since therefore never published the settings its profiles really had, and a new device
    /// found nothing. A migration seed is those real settings, so it goes up as soon as iCloud is
    /// confirmed to hold nothing for it; a record that is there wins instead, as it always did.
    /// Copies of another profile (a new profile on this device) stay local.
    private func claimUnclaimedMigrationSeeds() async {
        let registry = dependencies.profileSettings
        let candidates = registry.unclaimedMigrationSeeds()
        guard !candidates.isEmpty, let database else { return }
        let ids = candidates.map { recordID(CloudSyncRecordName.profile($0.kind, $0.key)) }
        do {
            let results = try await database.records(for: ids)
            var claimed = 0
            var adopted = 0
            for candidate in candidates {
                let id = recordID(CloudSyncRecordName.profile(candidate.kind, candidate.key))
                switch results[id] {
                case .success(let record)?:
                    applyRemoteRecord(record)
                    adopted += 1
                case .failure(let error as CKError)? where error.code == .unknownItem:
                    registry.claim(candidate.key, candidate.kind)
                    uploadProfileIfChanged(candidate.kind, candidate.key)
                    claimed += 1
                default:
                    break
                }
            }
            LogTap.shared.note("[CloudSync] migration seeds: \(claimed) uploaded, \(adopted) taken from iCloud, \(candidates.count - claimed - adopted) left for later")
        } catch {
            LogTap.shared.note("[CloudSync] migration seed check failed: \(error)")
        }
    }

    /// The skip line names the key that failed, which a bare `try?` threw away: "did not decode" was
    /// all a device log said about a record that a late non-optional field had locked out for good.
    private func decodeOrSkip<T>(_ name: String, _ kind: String, _ decode: () throws -> T) -> T? {
        do {
            return try decode()
        } catch {
            noteSkipped(name, reason: "\(kind) payload did not decode (\(Self.decodeFailure(error)))")
            return nil
        }
    }

    /// Key paths only, never values: the payloads carry tokens and passwords.
    nonisolated static func decodeFailure(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(type(of: error))" }
        func path(_ context: DecodingError.Context, _ last: CodingKey? = nil) -> String {
            let keys = context.codingPath + (last.map { [$0] } ?? [])
            return keys.isEmpty ? "root" : keys.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context): return "missing \(path(context, key))"
        case let .typeMismatch(_, context): return "wrong type at \(path(context))"
        case let .valueNotFound(_, context): return "null at \(path(context))"
        case let .dataCorrupted(context): return "corrupt at \(path(context))"
        @unknown default: return "undecodable"
        }
    }

    private func noteSkipped(_ name: String, reason: String) {
        preferences.noteSkippedRecord(name)
        LogTap.shared.note("[CloudSync] \(reason) on \(name), record skipped, retried on the next start")
    }

    static func applyOrder(_ recordName: String) -> Int {
        if CloudSyncRecordName.storeKey(fromRecordName: recordName) != nil { return 0 }
        if CloudSyncRecordName.serverID(fromRecordName: recordName) != nil { return 1 }
        if CloudSyncRecordName.profileRecord(fromRecordName: recordName) != nil { return 2 }
        return 3
    }

    /// Record names for the log with the per-profile and per-server part cut to its kind, so a line
    /// says what moved without listing identifiers.
    static func summary(_ names: [String]) -> String {
        guard !names.isEmpty else { return "none" }
        var counts: [String: Int] = [:]
        for name in names {
            let kind: String
            if case let (profileKind, _)? = CloudSyncRecordName.profileRecord(fromRecordName: name) {
                kind = "profile-\(profileKind.rawValue)"
            } else if CloudSyncRecordName.serverID(fromRecordName: name) != nil {
                kind = "server"
            } else {
                kind = name
            }
            counts[kind, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    }

    #if DEBUG
    /// Test-only seam: lets unit tests drive waitForInitialSync's polling branch
    /// without spinning up a real CKSyncEngine (start() touches CloudKit).
    func setStatusForTesting(_ status: CloudSyncStatus) { self.status = status }
    #endif
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine this service already let go of (a resync, a teardown, a failed adoption) can still
        // deliver the tail of its cycle. Its state update wrote a stale change token back over the
        // fresh engine's, and its account change tore down the start that replaced it.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            preferences.engineState = try? JSONEncoder().encode(update.stateSerialization)

        case .accountChange(let change):
            applyAccountChange(change.changeType)

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID.zoneName == Self.zoneName {
                switch deletion.reason {
                case .encryptedDataReset:
                    // The user reset their encrypted iCloud data: the records are gone but nobody
                    // asked for the data to go, so this device puts its state back.
                    LogTap.shared.note("[CloudSync] zone reset by an encrypted-data reset, re-uploading")
                    preferences.resetForZoneRecreation()
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    completeAdoption()
                default:
                    // Only a device that had adopted the zone has local data to protect from it. One
                    // that is adopting right now (just enabled, or re-enabled after deleting its iCloud
                    // data) reads the zone's history from scratch and meets the deletion it is
                    // recovering from; the switch it just flipped is the consent to create it again.
                    guard preferences.adoptionCompleted else {
                        LogTap.shared.note("[CloudSync] zone deletion from before this device adopted, recreating the zone")
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                        continue
                    }
                    turnOffForDeletedZone(reason: "zone deleted remotely")
                }
            }

        case .sentDatabaseChanges(let sent):
            for failed in sent.failedZoneSaves where failed.zone.zoneID == Self.zoneID {
                LogTap.shared.note("[CloudSync] zone save failed: \(failed.error.code.rawValue)")
                if CloudSyncRecovery.saveAction(for: failed.error) == .retry {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(failed.zone)])
                }
            }
            // A zone that is already gone (another device deleted it first) is the outcome asked for.
            if let error = sent.failedZoneDeletes[Self.zoneID],
               error.code != .zoneNotFound, error.code != .userDeletedZone {
                zoneDeleteFailure = error
                LogTap.shared.note("[CloudSync] zone delete failed: \(error.code.rawValue)")
            }

        case .fetchedRecordZoneChanges(let changes):
            // Settings first, then servers, then profiles: a profile record for a profile this
            // device has never seen seeds the kinds it does not carry from the legacy settings and
            // the server's rows, so those have to be in place before it lands.
            let ordered = changes.modifications.map(\.record)
                .sorted { Self.applyOrder($0.recordID.recordName) < Self.applyOrder($1.recordID.recordName) }
            for record in ordered {
                applyRemoteRecord(record)
            }
            for deletion in changes.deletions {
                applyRemoteDeletion(recordName: deletion.recordID.recordName)
            }
            if !ordered.isEmpty || !changes.deletions.isEmpty {
                LogTap.shared.note(
                    "[CloudSync] fetched \(ordered.count) record(s), \(changes.deletions.count) deletion(s): \(Self.summary(ordered.map(\.recordID.recordName)))"
                )
            }
            preferences.lastSyncAt = Date()
            settleActive()
            NotificationCenter.default.post(name: .cloudSyncDidApplyChanges, object: nil)

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                let name = saved.recordID.recordName
                preferences.setSystemFields(Self.encodeSystemFields(saved), for: name)
                let sentStamp = inFlightStamps.removeValue(forKey: name)
                if Self.editedWhileInFlight(sent: sentStamp, local: preferences.localStamp(for: name)) {
                    addPendingSave(recordName: name)
                } else {
                    preferences.unstashPendingSave(name)
                }
            }
            if !sent.savedRecords.isEmpty || !sent.failedRecordSaves.isEmpty {
                LogTap.shared.note(
                    "[CloudSync] sent \(sent.savedRecords.count) record(s), \(sent.failedRecordSaves.count) failed: \(Self.summary(sent.savedRecords.map(\.recordID.recordName)))"
                )
            }
            // An upload that lands is the only evidence that clears a latched rejection, and it
            // has to clear before this batch's own failures are handled: a batch that saved some
            // records and had others permanently rejected must come out latched, not healthy.
            if !sent.savedRecords.isEmpty { statusLatch.clear() }
            for failure in sent.failedRecordSaves {
                handleSaveFailure(failure, syncEngine: syncEngine)
            }
            for (recordID, error) in sent.failedRecordDeletes {
                handleDeleteFailure(recordName: recordID.recordName, error: error, syncEngine: syncEngine)
            }
            // Deletes actually confirmed sent no longer need resurrection protection.
            recentLocalDeletes.subtract(sent.deletedRecordIDs.map(\.recordName))
            for deleted in sent.deletedRecordIDs { preferences.unstashPendingDelete(deleted.recordName) }
            // A manual push or a resync waits in `.syncing`; one whose every save failed must not
            // settle to "Active" afterwards as if it had landed.
            // Only failures nothing will retry count: a conflict or a transient error is re-queued and
            // lands in the next batch, and a resync started above owns the status itself.
            if sent.savedRecords.isEmpty, resyncTask == nil, case .syncing = status,
               let terminal = sent.failedRecordSaves.first(where: {
                   CloudSyncRecovery.saveAction(for: $0.error).isTerminal
               }) {
                status = .error(CloudSyncRecovery.describe(terminal.error))
            }
            if !sent.savedRecords.isEmpty {
                preferences.lastSyncAt = Date()
                settleActive()
            }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        // Materialize records on the MainActor up front: the recordProvider closure
        // below is @Sendable (CKSyncEngine may invoke it off-actor), so it cannot
        // call the MainActor-isolated buildRecord itself.
        let built: [CKRecord.ID: CKRecord] = pending.reduce(into: [:]) { result, change in
            if case .saveRecord(let recordID) = change, let record = buildRecord(recordName: recordID.recordName) {
                result[recordID] = record
            }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            built[recordID]
        }
    }

    private static var rejectedMessage: String {
        String(
            localized: "cloudSync.error.rejected",
            defaultValue: "iCloud rejected this device's data. This is a fault in Sodalite, not on your device."
        )
    }

    /// Internal for tests.
    nonisolated static func editedWhileInFlight(sent: Date?, local: Date?) -> Bool {
        guard let sent, let local else { return false }
        return local > sent
    }

    /// Deleted on purpose, from another device's "Delete iCloud Data" or from the iCloud storage
    /// settings. Re-uploading undid that the moment any other device came to the foreground, so this
    /// one stops and keeps its local data, which is what the deletion's confirmation promises.
    private func turnOffForDeletedZone(reason: String) {
        LogTap.shared.note("[CloudSync] \(reason), sync turned off here, local data kept")
        preferences.resetForCloudDataDeletion()
        preferences.isEnabled = false
        teardownEngine()
        statusLatch.clear()
        status = .disabled
    }

    /// After adoption a missing zone is either a deletion this device has not heard of yet or a zone
    /// lost some other way. One fetch tells them apart: a deletion arrives as a database change and
    /// turns sync off, and only if the engine is still running afterwards is the zone recreated.
    private func checkZoneBeforeRecreating(_ syncEngine: CKSyncEngine) {
        guard zoneCheckTask == nil else { return }
        let generation = observationGeneration
        zoneCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Only its own slot: after a teardown and restart the slot may belong to a newer check.
            defer { if self.observationGeneration == generation { self.zoneCheckTask = nil } }
            do {
                try await syncEngine.fetchChanges()
            } catch let error as CKError where error.code == .zoneNotFound {
                // The fetch itself found no zone and reported no deletion: nothing says it was
                // removed on purpose, so it is recreated below rather than left missing forever.
                LogTap.shared.note("[CloudSync] zone check fetch found no zone")
            } catch {
                LogTap.shared.note("[CloudSync] zone check fetch failed, saves kept for the next start: \(error)")
                return
            }
            let names = self.zoneMissingSaves
            self.zoneMissingSaves = []
            guard self.engine === syncEngine, self.preferences.isEnabled else { return }
            LogTap.shared.note("[CloudSync] zone missing but not deleted, recreating it")
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            for name in names { self.addPendingSave(recordName: name) }
        }
    }

    /// A sign-out keeps everything tied to the account: the account id is what lets the next start
    /// tell "the same person signed back in" from "someone else did". Wiping it here made the next
    /// start a first adoption, which uploads every server with its tokens, passwords and Seerr
    /// sessions into whichever account is signed in by then. A switch goes straight to the lockout
    /// the start path uses for the same situation. Internal for tests.
    func applyAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signOut:
            teardownEngine()
            statusLatch.clear()
            status = .noAccount
            LogTap.shared.note("[CloudSync] signed out of iCloud, sync paused, local state kept for that account")
        case .switchAccounts:
            teardownEngine()
            lockOutForAccountChange()
        default:
            break
        }
    }

    private func handleSaveFailure(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) {
        handleSaveFailure(
            recordName: failure.record.recordID.recordName,
            error: failure.error,
            syncEngine: syncEngine
        )
    }

    /// A send that fails as a whole reports its per-record errors only inside the thrown partial
    /// error. Without routing those here they never reach the recovery below, and a record the
    /// server permanently rejects keeps being rejected on every future attempt.
    private func handlePartialSendFailure(_ error: Error, syncEngine: CKSyncEngine) {
        for (recordID, itemError) in CloudSyncRecovery.partialSaveErrors(in: error) {
            handleSaveFailure(recordName: recordID.recordName, error: itemError, syncEngine: syncEngine)
        }
    }

    /// Nothing handled these before, so a delete that failed once was simply forgotten: the record
    /// stayed in the cloud and came back on the next device's adoption, and its name stayed in the
    /// resurrection guard for the rest of the session.
    private func handleDeleteFailure(recordName: String, error: CKError, syncEngine: CKSyncEngine) {
        switch CloudSyncRecovery.deleteAction(for: error) {
        case .alreadyGone:
            recentLocalDeletes.remove(recordName)
            preferences.removeRecordCaches(for: recordName)
            preferences.unstashPendingDelete(recordName)
        case .retry:
            syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(recordName))])
        case .report:
            // Left in the outbox: replayed on the next start rather than forgotten.
            LogTap.shared.note("[CloudSync] delete failed \(recordName): \(error.code.rawValue), kept for the next start")
        }
    }

    private func handleSaveFailure(recordName: String, error: CKError, syncEngine: CKSyncEngine) {
        // Off the outbox unless a branch below queues it again: a save the server keeps refusing
        // would otherwise be replayed on every launch.
        preferences.unstashPendingSave(recordName)
        guard !deletingZone else { return }
        switch CloudSyncRecovery.saveAction(for: error) {
        case .adoptServerRecord:
            guard let serverRecord = error.serverRecord else { return }
            // Adopt the server's system fields, then LWW: apply theirs if newer,
            // else re-queue ours (now based on their record, so the save sticks).
            preferences.setSystemFields(Self.encodeSystemFields(serverRecord), for: recordName)
            applyRemoteRecord(serverRecord)
            // applyRemoteRecord gives up on a record whose payload it cannot read, which would
            // drop our save with it. The identity is learned either way, so re-queue.
            if serverRecord.encryptedValues[Self.payloadKey] as? Data == nil {
                addPendingSave(recordName: recordName)
            }
        case .resyncZone:
            // The engine no longer holds this save, so the resync's stash would miss it.
            preferences.stashPendingSave(recordName)
            resyncZoneFromScratch(
                reason: "save rejected as an insert of an existing record (\(recordName))",
                afterRejectedSave: true
            )
        case .reinsert:
            preferences.removeSystemFields(for: recordName)
            addPendingSave(recordName: recordName)
        case .recreateZone:
            guard preferences.adoptionCompleted else {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                addPendingSave(recordName: recordName)
                return
            }
            // Kept in the outbox, not handed back to the engine until the check below has run.
            preferences.stashPendingSave(recordName)
            zoneMissingSaves.insert(recordName)
            checkZoneBeforeRecreating(syncEngine)
        case .zoneDeletedByUser:
            turnOffForDeletedZone(reason: "zone deleted from the iCloud settings")
        case .retry:
            addPendingSave(recordName: recordName)
        case .surfaceQuota:
            // Deferred, not dropped: it goes again on the next start, once there may be room.
            preferences.stashPendingSave(recordName)
            latchFailure(ErrorText.user(for: error))
            LogTap.shared.note("[CloudSync] iCloud quota exceeded, save deferred: \(recordName)")
        case .surfaceRejection:
            // CloudKit's own text here is "Invalid Arguments", which tells a user nothing; the
            // part worth reading ("Cannot create new type … in production schema") is a server
            // message and goes to the diagnostic log, where a bug report can carry it.
            latchFailure(Self.rejectedMessage)
            LogTap.shared.note("[CloudSync] save rejected as invalid \(recordName): \(error)")
        case .report:
            // Unclassified is not the same as permanent: kept for the next start instead of lost
            // until someone happens to edit the same setting again.
            preferences.stashPendingSave(recordName)
            LogTap.shared.note("[CloudSync] save failed \(recordName): \(error.code.rawValue), kept for the next start")
        }
    }
}
