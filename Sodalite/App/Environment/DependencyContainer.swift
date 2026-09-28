import Foundation
import AetherEngine

@MainActor
@Observable
final class DependencyContainer {
    /// Single instance (App `@State` + `@Environment` default both resolve here). A second container spawns a zombie MusicPlaybackCoordinator that clears system Now-Playing on every engine state change.
    static let shared = DependencyContainer()

    @MainActor static let playerEngine: AetherEngine = {
        let engine = try! AetherEngine()
        // AetherEngine #215: nothing in this app plays audio outside the engine, so the engine may release
        // the shared AVAudioSession when playback ends. Without it, an E-AC-3/Atmos bitstream-passthrough
        // route leaves the HDMI sink looping the last MAT frame after the player is gone.
        engine.deactivatesAudioSessionOnStop = true
        return engine
    }()
    let keychainService: KeychainServiceProtocol
    let httpClient: HTTPClientProtocol
    /// Seerr's own client, kept so the caches screen can reach the handle it holds on the shared response store.
    let seerrHTTPClient: HTTPClient

    /// Which server certificates this device has been told to accept. The store itself is
    /// process-wide (see `ServerTrustDelegate.shared`, which the first `HTTPClient` needs before this
    /// container's body runs); this is the handle everything else reads it through, so no view model
    /// reaches the keychain for it.
    var serverTrustStore: ServerTrustStore { ServerTrustDelegate.shared.store }
    let jellyfinClient: JellyfinClient
    let serverDiscoveryService: ServerDiscoveryServiceProtocol
    let serverDiscovery: JellyfinServerDiscoveryProtocol
    let jellyfinAuthService: JellyfinAuthServiceProtocol
    let jellyfinLibraryService: JellyfinLibraryServiceProtocol
    let jellyfinLiveTvService: JellyfinLiveTvServiceProtocol
    let jellyfinMusicService: JellyfinMusicServiceProtocol
    let jellyfinItemService: JellyfinItemServiceProtocol
    let jellyfinImageService: JellyfinImageService
    let jellyfinPlaybackService: JellyfinPlaybackServiceProtocol
    /// Per-profile playback and appearance settings plus the shared device values. The two
    /// properties below resolve to the active profile, so a view that reads them follows a switch.
    let profileSettings: ProfileSettingsRegistry
    var playbackPreferences: PlaybackPreferences { profileSettings.current.playback }
    var appearancePreferences: AppearancePreferences { profileSettings.current.appearance }
    var devicePreferences: DevicePreferences { profileSettings.device }
    let trackSelectionMemory: TrackSelectionMemory
    /// Remembered provider URLs for direct-played live channels, so a zap skips Jellyfin's tuner open.
    let liveDirectStreamMemory: LiveDirectStreamMemory
    let spoilerRevealMemory: SpoilerRevealMemory
    let spoilerSeriesRules: SpoilerSeriesRules
    let storeKitService: StoreKitServiceProtocol
    /// Sodalite#79. One store for the whole app so a title enriched in a Home row is already known
    /// when the same title shows up in a grid.
    let posterBadgeStore: PosterBadgeStore
    /// AE#579. The detail page's HDR10+ answer, which no Jellyfin field carries.
    let hdr10PlusProbeStore: HDR10PlusProbeStore
    let authPreferences: AuthPreferences
    let parentalControlsPreferences: ParentalControlsPreferences
    let parentalGate: ParentalGate
    /// Sodalite#81. The on-disk truth of the downloads; empty on tvOS, where nothing downloads.
    let downloadStore = DownloadStore(paths: DownloadPaths(root: DownloadPaths.defaultRoot()))
    let downloadPreferences: DownloadPreferences
    /// Nil on tvOS. Created last in init because its backend reads the session through the container.
    private(set) var downloadManager: DownloadManager?

    let seerrClient: SeerrClient
    let seerrServerDiscoveryService: SeerrServerDiscoveryServiceProtocol
    /// `var` only so a test can hold the Seerr round trip open across a profile switch.
    var seerrAuthService: SeerrAuthServiceProtocol
    let seerrDiscoverService: SeerrDiscoverServiceProtocol
    let seerrMediaService: SeerrMediaServiceProtocol
    let seerrRequestService: SeerrRequestServiceProtocol
    let seerrServiceConfigService: SeerrServiceConfigServiceProtocol
    let seerrSearchService: SeerrSearchServiceProtocol

    /// Opt-in + baseline for the pending-requests notification feature (iOS/iPadOS).
    let seerrNotificationPreferences: SeerrNotificationPreferences
    /// Count of requests pending approval (admin only); feeds the Catalog tab badge + background refresh.
    let pendingRequestsMonitor: PendingRequestsMonitor

    /// File-deletion service fronting Jellyfin + Seerr; gated on JellyfinUser.canDeleteContent.
    let mediaDeletionService: any MediaDeletionServiceProtocol

    let musicPlaybackCoordinator: MusicPlaybackCoordinator

    /// Back-reference so switchServer / removeServer can bump serverDidSwitch. Weak: AppState does not own the container.
    weak var appState: AppState?

    /// True while cloud sync applies remote changes, so the mutation hooks below
    /// do not echo those writes back to CloudKit. Also consulted by
    /// CloudSyncService's settings observation.
    var isApplyingCloudChanges = false

    /// Cloud sync engine; attached from SodaliteApp.init after the container is
    /// fully built (the service needs a back-reference to the container).
    var cloudSync: CloudSyncServiceProtocol?

    /// When each server's remembered profiles were last held against its user table (Sodalite#90),
    /// so the launch pass and the picker that comes up right behind it do not each ask.
    var lastProfileReconcile: [String: Date] = [:]

    /// Bumped by every `syncSeerrSession`, so a call that a newer one overtook leaves the live
    /// client alone after its await.
    var seerrSyncGeneration = 0

    /// Dual-URL routing state. Routes are per active session; nil when the
    /// active server has no resolved route yet.
    let serverRouteStore: ServerRouteStore
    /// When each server was added and when its URL slots were last edited, which is what a removal
    /// tombstone and a URL edit have to outrank a stale republish with.
    let serverSyncMetadata: ServerSyncMetadataStore
    /// How a Jellyfin address is asked whether it answers AS the server with this id. A stored
    /// closure so the sign-in route can be tested without a network; the app never replaces it.
    var jellyfinProbe: @Sendable (URL, String) async -> Bool = {
        await ServerProbe.jellyfin($0, expectedServerID: $1)
    }
    var activeJellyfinRoute: ServerRoute?
    /// Jellyfin's internal address answered its identity probe in the last resolve, which is what
    /// lets Seerr use its own internal address (`ServerRouteResolver.seerrSlots`).
    var isOnVerifiedHomeNetwork = false
    var activeSeerrRoute: ServerRoute?
    var routeResolveTask: Task<Void, Never>?
    /// One re-measure at a time after a transport failure, and the moment it last ran (Sodalite#126).
    var transportRecheckTask: Task<Void, Never>?
    var lastTransportRecheck: ContinuousClock.Instant?
    /// Runs only while the verdict is a failure, and asks again until it is not.
    var reachabilityWatchTask: Task<Void, Never>?

    /// Attach + start cloud sync. Idempotent.
    func attachCloudSync() {
        guard cloudSync == nil else { return }
        let service = CloudSyncService(dependencies: self)
        cloudSync = service
        service.start()
    }

    /// Mutation hook: mark a server record dirty unless the write came FROM the cloud.
    private func cloudSyncMarkServer(_ serverID: String) {
        guard !isApplyingCloudChanges else { return }
        cloudSync?.markServerDirty(serverID: serverID)
    }

    /// `defaults` is the suite every preference store here reads and writes. One parameter rather
    /// than ten, so a test can stand up two containers that are genuinely two DEVICES: sharing
    /// `.standard` between them made each one see the other's local bookkeeping, which is precisely
    /// the state a sync merge is supposed to be deciding between.
    init(
        keychainService: KeychainServiceProtocol = KeychainService(),
        httpClient: HTTPClientProtocol = HTTPClient(),
        discoveryHTTPClient: HTTPClientProtocol? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.serverRouteStore = ServerRouteStore(defaults: defaults)
        self.serverSyncMetadata = ServerSyncMetadataStore(defaults: defaults)
        self.keychainService = keychainService
        self.httpClient = httpClient
        self.jellyfinClient = JellyfinClient(httpClient: httpClient)
        // Both discovery services share ONE client of their own: a probe the user is watching a
        // spinner for must not queue behind Home's fan-out or Catalog's rows, and the transport
        // timing that says which phase ate a capped probe belongs on discovery only (Sodalite#82).
        let discoveryClient: HTTPClientProtocol = discoveryHTTPClient ?? HTTPClient.discovery()
        self.serverDiscoveryService = ServerDiscoveryService(httpClient: discoveryClient)
        self.serverDiscovery = JellyfinServerDiscovery()
        self.jellyfinAuthService = JellyfinAuthService(client: jellyfinClient)
        self.jellyfinLibraryService = JellyfinLibraryService(client: jellyfinClient)
        self.jellyfinLiveTvService = JellyfinLiveTvService(client: jellyfinClient)
        self.jellyfinMusicService = JellyfinMusicService(
            client: jellyfinClient,
            libraryService: jellyfinLibraryService
        )
        self.jellyfinItemService = JellyfinItemService(client: jellyfinClient)
        self.jellyfinImageService = JellyfinImageService(
            baseURLProvider: { [weak jellyfinClient] in
                jellyfinClient?.baseURL
            },
            accessTokenProvider: { [weak jellyfinClient] in
                jellyfinClient?.accessToken
            }
        )
        self.jellyfinPlaybackService = JellyfinPlaybackService(client: jellyfinClient)
        let profileSettings = ProfileSettingsRegistry(defaults: defaults)
        self.profileSettings = profileSettings
        self.trackSelectionMemory = TrackSelectionMemory(store: defaults)
        self.liveDirectStreamMemory = LiveDirectStreamMemory(keychain: keychainService)
        self.spoilerRevealMemory = SpoilerRevealMemory(store: defaults)
        self.spoilerSeriesRules = SpoilerSeriesRules(store: defaults)
        self.storeKitService = StoreKitService()
        self.posterBadgeStore = PosterBadgeStore(
            library: self.jellyfinLibraryService,
            isEnabled: { profileSettings.current.appearance.showPosterBadges }
        )
        // Static=true, so the probe always opens the original file and never a transcode.
        let playbackService = self.jellyfinPlaybackService
        self.hdr10PlusProbeStore = HDR10PlusProbeStore(
            streamURL: { itemID, sourceID, container in
                playbackService.buildStreamURL(
                    itemID: itemID, mediaSourceID: sourceID, container: container, isStatic: true)
            },
            isEnabled: { profileSettings.current.appearance.showDetailBadges }
        )
        self.authPreferences = AuthPreferences(store: defaults)
        // The pre-1.0 default-profile pin had no server scope; attribute it to the pinned default server, else the one that was active when it was written.
        self.authPreferences.migrateLegacyDefaultUserID(
            toServerID: self.authPreferences.defaultServerID
                ?? (try? keychainService.loadString(for: KeychainKeys.activeServerID))
        )
        self.parentalControlsPreferences = ParentalControlsPreferences(store: defaults)
        self.parentalGate = ParentalGate()
        self.downloadPreferences = DownloadPreferences(store: defaults)

        // Seerr gets its OWN HTTPClient so Catalog browsing doesn't compete with the Home fan-out for the same 6 in-flight permits against a tarpitted Jellyfin CDN (see HTTPClient inFlightLimiter).
        let seerrHTTPClient = HTTPClient()
        // Kept rather than handed straight to SeerrClient: it holds the second handle on the shared
        // response cache, and Settings clears both (see DependencyContainer+Caches).
        self.seerrHTTPClient = seerrHTTPClient
        self.seerrClient = SeerrClient(httpClient: seerrHTTPClient)
        self.seerrServerDiscoveryService = SeerrServerDiscoveryService(httpClient: discoveryClient)
        self.seerrAuthService = SeerrAuthService(client: seerrClient)
        self.seerrDiscoverService = SeerrDiscoverService(client: seerrClient)
        self.seerrMediaService = SeerrMediaService(client: seerrClient)
        self.seerrRequestService = SeerrRequestService(client: seerrClient)
        self.seerrServiceConfigService = SeerrServiceConfigService(client: seerrClient)
        self.seerrSearchService = SeerrSearchService(client: seerrClient)

        self.seerrNotificationPreferences = SeerrNotificationPreferences(defaults: defaults)
        self.pendingRequestsMonitor = PendingRequestsMonitor()

        self.mediaDeletionService = MediaDeletionService(
            jellyfinItems: self.jellyfinItemService,
            seerrMedia: self.seerrMediaService,
            seerrRequests: self.seerrRequestService,
            isSeerrAuthenticated: { [weak seerrClient] in
                // Live read each invocation (no caching); cookie is set on login, cleared on logout/restore failure.
                seerrClient?.sessionCookie != nil
            }
        )

        // userIDProvider captures keychainService strongly (safe: coordinator lifetime is scoped to the container). Replicates activeUserID without closing over self, forbidden pre-init.
        let capturedKeychain = keychainService
        self.musicPlaybackCoordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: jellyfinPlaybackService,
            imageService: jellyfinImageService,
            userIDProvider: {
                guard let serverID = try? capturedKeychain.loadString(for: KeychainKeys.activeServerID)
                else { return nil }
                return try? capturedKeychain.loadString(for: KeychainKeys.userID(serverID: serverID))
            }
        )

        // Idempotent, and cheap once the legacy entries are gone (one miss per known server).
        migrateLegacyJellyfinPasswords()
        // Latched, and a no-op on any install that never configured parental controls.
        migrateUnmarkedProfilesToEntryLocked()
        // Sheds the pre-scoping filter-cache files on an install that never switches server or
        // profile, which no switch-site trim would ever reach.
        trimFilterCache(keeping: activeSessionIdentity())

        // Sodalite#126, and last because it captures self. The Jellyfin client alone: a Seerr
        // timeout says nothing about which Jellyfin address answers. Concrete client only, since
        // the hook is a real-transport concern and a mock has no verdict to keep honest.
        (httpClient as? HTTPClient)?.onServerDidNotServe = { [weak self] in
            Task { @MainActor in self?.noteServerDidNotServe() }
        }

        // Every credential the session holds is named to both log redactors as it arrives, so a line
        // carrying it in an encoding no key matcher knows still loses it (audit DIAG-1).
        jellyfinClient.onAccessTokenSet = { LogSecrets.register($0) }
        seerrClient.onSessionCookieSet = { LogSecrets.registerCookie($0) }

        // Last, because the closures capture self and the migration reads the keychain through it.
        profileSettings.activeKey = { [weak self] in self?.appState?.profileKey }
        profileSettings.isApplyingCloudChanges = { [weak self] in self?.isApplyingCloudChanges ?? false }
        profileSettings.migrateIfNeeded(profiles: profileKeysOnThisDevice())
        profileSettings.markEarlierMigrationSeedsIfNeeded()

        #if os(iOS)
        downloadManager = makeDownloadManager()
        #endif
    }

    /// Trims the filter cache to its identity limit off the main actor (synchronous directory IO),
    /// keeping the session being switched to. Doubles as the filename-format migration: it deletes
    /// what the previous format wrote wherever it runs.
    private func trimFilterCache(keeping survivor: CacheIdentity?) {
        Task.detached(priority: .utility) {
            FilterCache.shared.migrateAndTrim(keeping: survivor)
        }
    }

    /// Connect the pending-requests monitor to the live session. Called once from SodaliteApp.init
    /// right after `appState` is back-wired, so the closures capture the fully-initialized container.
    func wirePendingRequestsMonitor() {
        pendingRequestsMonitor.isEligible = { [weak self] in
            guard let self, let user = self.appState?.activeSeerrUser else { return false }
            return (self.appState?.isSeerrConnected ?? false) && user.canManageRequests
        }
        pendingRequestsMonitor.fetchPendingCount = { [weak self] in
            guard let self else { return 0 }
            let result = try await self.seerrRequestService.allRequests(filter: .pending, take: 0, skip: 0)
            return result.pageInfo.results
        }
    }

    /// Probes the active server's session for AppRouter's post-switch routing. Returns the user when
    /// the token still resolves (or a stored password minted a fresh one); nil when the server refused
    /// it and the profile was dropped, or when there is no session to probe (caller routes to the
    /// picker); throws on transport errors (caller keeps the previous server active).
    ///
    /// Deliberately does no routing of its own: this runs inside AppRouter's `.task(id: serverDidSwitch)`,
    /// and a bump from in here would re-key that task and cancel the probe mid-flight.
    @MainActor
    func probeActiveUser() async throws -> JellyfinUser? {
        switch await checkActiveSession() {
        case .valid(let user):
            return user
        case .rejected, .noSession:
            return nil
        case .unreachable(let error):
            throw error
        }
    }

    /// Gates the Live TV tab: does the active server expose any Live TV channels? False on any error.
    func serverHasLiveTV(userID: String) async -> Bool {
        do {
            let response = try await jellyfinLiveTvService.getChannels(
                userID: userID, startIndex: 0, limit: 1, filter: .any)
            return !response.items.isEmpty
        } catch {
            return false
        }
    }

    /// Silent `try?`: a missing/unreadable keychain entry means no session to restore (app falls back to login); no recovery path benefits from the underlying error.
    func restoreSession() -> Bool {
        guard let server = activeServer else {
            sessionNote("restore: no active server pointer, \(listKnownServers().count) server(s) known.")
            return false
        }
        guard let token = try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))
        else {
            sessionNote("restore: \(label(for: server)) has no token slot on this device, \(listRememberedUsers(serverID: server.id).count) remembered profile(s).")
            return false
        }

        let sessionURL = preferredURL(for: server)
        jellyfinClient.baseURL = sessionURL
        jellyfinClient.accessToken = token

        // Re-project SharedSessionMirror every cold launch so TopShelf stays in lockstep even if a prior version never wrote it or the shelf's bucket was wiped.
        if let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)) {
            SharedSessionMirror.write(
                serverURL: sessionURL,
                userID: userID,
                accessToken: token
            )
        }
        scheduleRouteResolve()
        return true
    }

    func saveSession(
        server: JellyfinServer,
        user: JellyfinUser,
        token: String,
        password: String? = nil
    ) throws {
        try addServer(server)
        try keychainService.save(server.id, for: KeychainKeys.activeServerID)
        try keychainService.save(token, for: KeychainKeys.accessToken(serverID: server.id))
        try keychainService.save(user.id, for: KeychainKeys.userID(serverID: server.id))
        try keychainService.save(user.name, for: KeychainKeys.activeUserName)

        // Persist avatar tag for cold-launch rendering; clear a stale tag when the user has none so a removed image doesn't linger and 404.
        if let tag = user.primaryImageTag, !tag.isEmpty {
            try keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }

        if let password, !password.isEmpty {
            try keychainService.save(
                password,
                for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: user.id)
            )
        }

        let sessionURL = preferredURL(for: server)
        jellyfinClient.baseURL = sessionURL
        jellyfinClient.accessToken = token

        SharedSessionMirror.write(
            serverURL: sessionURL,
            userID: user.id,
            accessToken: token
        )

        // Upsert into remembered-profiles so the user can later switch profiles without re-auth.
        try rememberUser(
            RememberedUser(
                id: user.id,
                serverID: server.id,
                name: user.name,
                imageTag: user.primaryImageTag,
                token: token
            )
        )


        cloudSyncMarkServer(server.id)
        scheduleRouteResolve()
    }

    // MARK: - Known Servers

    /// All servers ever logged into and not removed, most-recently-upserted first. Empty on fresh install / all removed.
    func listKnownServers() -> [JellyfinServer] {
        guard let data = try? keychainService.loadData(for: KeychainKeys.knownServers)
        else { return [] }
        return (try? JSONDecoder().decode([JellyfinServer].self, from: data)) ?? []
    }

    /// Upsert by id, prepending so a re-added server (e.g. changed URL) updates in place and floats to the top of pickers.
    /// URL slots the incoming server leaves empty are carried over from the stored entry (Sodalite#45):
    /// every login path knows one address only, and this upsert marks the record dirty, so a plain
    /// re-login used to erase the other slot on every device. tvOS has no URL editor at all.
    func addServer(_ server: JellyfinServer) throws {
        let stored = listKnownServers()
        let merged = stored.first(where: { $0.id == server.id })
            .map { server.fillingEmptyURLSlots(from: $0) } ?? server
        var servers = stored.filter { $0.id != server.id }
        servers.insert(merged, at: 0)
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
        appState?.updateActiveServer(merged)
        // Signing in is the deliberate act that takes a removal back, so it has to outrank the
        // tombstone rather than be held out by it. Only a re-add moves the stamp: an ordinary
        // re-login on a server that was never removed must not look like a fresh add.
        if !isApplyingCloudChanges, authPreferences.forgottenServers[server.id] != nil {
            // The auth record carries the tombstone map; the settings observation picks the change
            // up and republishes it, the same way every other auth preference travels.
            authPreferences.forgottenServers[server.id] = nil
            serverSyncMetadata.noteReAdded(serverID: server.id)
        } else {
            serverSyncMetadata.noteAdded(serverID: server.id)
        }
        cloudSyncMarkServer(server.id)
    }

    /// In-place update preserving list order (unlike addServer) so a background version refresh doesn't reshuffle the picker. No-op if id unknown.
    private func updateKnownServer(_ server: JellyfinServer) throws {
        var servers = listKnownServers()
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
    }

    /// Rewrites a known server's URL slots (iOS edit sheet). Order-preserving,
    /// mirrors to cloud sync, and re-resolves immediately when it is the
    /// active server so the session moves without a restart.
    func updateServerURLs(serverID: String, internalURL: URL?, externalURL: URL?) throws {
        guard internalURL != nil || externalURL != nil else { return }
        var servers = listKnownServers()
        guard let idx = servers.firstIndex(where: { $0.id == serverID }) else { return }
        let current = servers[idx]
        let updated = JellyfinServer(
            id: current.id,
            name: current.name,
            internalURL: internalURL,
            externalURL: externalURL,
            version: current.version
        )
        servers[idx] = updated
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
        // Stamps the EDIT, not the write. The record-level stamp moves on every republish, so
        // without this a device that slept through the edit won it back with a stale copy. Only a
        // real change counts: saving the sheet unchanged is not news, and stamping it would let a
        // device outrank another device's genuine correction by opening a dialog and closing it.
        if !isApplyingCloudChanges, updated != current {
            serverSyncMetadata.noteURLsChanged(serverID: serverID)
        }
        cloudSyncMarkServer(serverID)
        appState?.updateActiveServer(updated)
        if activeServer?.id == serverID {
            jellyfinClient.baseURL = preferredURL(for: updated)
            scheduleRouteResolve()
        }
    }

    /// Refreshes the cached server version (captured once at discovery, else stale in Settings until logout/login) via the unauthenticated discovery probe; updates knownServers in place. Returns the refreshed server only if the version changed; nil otherwise. id guard rejects a different server answering at the URL.
    func refreshActiveServerVersion() async -> JellyfinServer? {
        guard let server = activeServer else { return nil }
        // Opening Settings is what runs this probe, so without a cause its [discovery] lines read like
        // a resume or a reconnect in a log exported from the same screen (Sodalite#117).
        LogTap.shared.note("[discovery] server version check, Settings opened")
        guard case .success(_, let info) = await serverDiscoveryService.discoverServer(
            input: server.url.absoluteString
        ) else { return nil }
        guard info.id == server.id, info.version != server.version else { return nil }
        let updated = JellyfinServer(
            id: server.id,
            name: server.name,
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            version: info.version
        )
        try? updateKnownServer(updated)
        return updated
    }

    /// Resolves the active-server pointer against knownServers. nil if missing or unresolved (the latter repaired in SessionRestorer.restore).
    var activeServer: JellyfinServer? {
        guard let id = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        else { return nil }
        return listKnownServers().first(where: { $0.id == id })
    }

    /// The active Jellyfin user's id, resolved from the keychain for the
    /// active server. nil when there is no active session.
    /// Sodalite#50. `userID` comes from `AppState.activeUser?.id`, not from `activeUserID`
    /// below: that one reads the keychain, and this is evaluated once per card body.
    func spoilerPolicy(userID: String?) -> SpoilerPolicy {
        SpoilerPolicy(
            enabled: appearancePreferences.spoilerProtectionEnabled,
            hideEpisodes: appearancePreferences.spoilerHideEpisodes,
            hideMovies: appearancePreferences.spoilerHideMovies,
            userID: userID ?? "",
            revealedKeys: spoilerRevealMemory.revealedKeys,
            seriesOverrides: spoilerSeriesRules.overrides
        )
    }

    var activeUserID: String? {
        guard let server = activeServer else { return nil }
        return try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
    }

    enum ServerSwitchError: LocalizedError {
        /// The requested server id was not in knownServers.
        case unknown
        /// The target server has no session this device can resume: no
        /// token of its own and no remembered profile that may be
        /// resumed unasked. The caller shows that server's profile
        /// picker (its cards, or a fresh sign-in, both live there).
        case missingToken

        /// `.missingToken` normally routes to the picker rather than to a message, but it reaches a
        /// viewer wherever a caller shows the throw instead, so it says something they can act on.
        var errorDescription: String? {
            switch self {
            case .unknown:
                String(
                    localized: "error.serverSwitch.unknown",
                    defaultValue: "This server is no longer saved on this device."
                )
            case .missingToken:
                String(
                    localized: "error.serverSwitch.missingToken",
                    defaultValue: "No sign-in is saved for this server. Sign in again to use it."
                )
            }
        }
    }

    /// One line of session bookkeeping into the buffer Settings > Diagnostic Log renders. The session
    /// layer used to write nothing there, so a switch that never reached the network left no evidence
    /// anywhere: not on the device, and not in the server's log either (Sodalite#76). Ids and names
    /// only, never a token or a password.
    func sessionNote(_ line: String) {
        LogTap.shared.note("[session] \(line)")
    }

    /// Short form for a log line: the name a person recognises plus enough id to tell two apart.
    private func label(for server: JellyfinServer) -> String {
        "\(server.name) [\(server.id.prefix(8))]"
    }

    /// The remembered profile a switch to `serverID` may resume without asking, when the server holds no
    /// session of its own on this device. That is the normal state for every server restored from iCloud:
    /// the token slot is deliberately device-local and never syncs, while the tokens themselves ride the
    /// remembered profiles (Sodalite#74). nil when the pick is not ours to make (several profiles and no
    /// pinned default, or one the Guardian PIN guards), which is what the profile picker is for.
    func resumableProfile(serverID: String) -> RememberedUser? {
        let remembered = listRememberedUsers(serverID: serverID)
        let pinned = authPreferences.defaultUserID(serverID: serverID)
            .flatMap { id in remembered.first { $0.id == id } }
        guard let candidate = pinned ?? (remembered.count == 1 ? remembered.first : nil),
              !candidate.token.isEmpty
        else { return nil }
        // Nobody identified themselves for this pick, so it has to clear the same bar the picker
        // would put in front of that card.
        guard !parentalGateRequired(forActivatingUserID: candidate.id, serverID: serverID)
        else { return nil }
        return candidate
    }

    /// Switches the active server: sets the pointer, loads the cached token, reconfigures JellyfinClient, rewrites SharedSessionMirror, bumps serverDidSwitch. Seerr is left to the caller's restore path. Throws .unknown (not in knownServers) or .missingToken (caller routes to the target's profile picker). Both throws land before the first write, so a switch that cannot complete leaves no half-switched session behind.
    func switchServer(to serverID: String) throws {
        guard let server = listKnownServers().first(where: { $0.id == serverID }) else {
            throw ServerSwitchError.unknown
        }

        // Resolve the session before anything is written. A server restored from iCloud has an empty
        // token slot, so its remembered profile is the second, equally valid reading of "signed in
        // here" (Sodalite#74); without it the switch died on a credential the device was holding.
        let cachedToken = try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: serverID))
        let resumable = cachedToken == nil ? resumableProfile(serverID: serverID) : nil
        guard let token = cachedToken ?? resumable?.token else {
            let remembered = listRememberedUsers(serverID: serverID)
            sessionNote(
                "switch to \(label(for: server)) has no session here: token slot empty, "
                + "\(remembered.count) remembered profile(s), "
                + "pin=\(authPreferences.defaultUserID(serverID: serverID) ?? "none"), "
                + "parentalControls=\(parentalControlsActive() ? "on" : "off"). Routing to its picker."
            )
            throw ServerSwitchError.missingToken
        }

        // Stop session-scoped background music at the source, before the session changes. The AppRouter
        // activeSessionIdentity onChange only catches the completed setAuthenticated, which lags the async
        // probe on a server switch, so the previous server's track would keep playing. Covers removeServer's
        // active-server promotion (it calls this).
        Task { @MainActor in
            if self.musicPlaybackCoordinator.currentItem != nil {
                self.musicPlaybackCoordinator.stop()
            }
        }

        if let resumable {
            sessionNote("switch to \(label(for: server)): no token slot here, resuming remembered profile \(resumable.name).")
            // Adopt the profile's own cached token as this device's session for the target: switchToUser
            // writes both pointers, re-stamps the name caches and drops the identity-scoped image
            // cache, so the keychain converges on exactly the state a tap in that server's picker
            // would have left.
            try switchToUser(resumable, server: server)
            Task { @MainActor in
                self.appState?.serverDidSwitch &+= 1
            }
            return
        }

        let previousServerID = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        sessionNote("switch \(previousServerID.map { String($0.prefix(8)) } ?? "none") -> \(label(for: server)) on this device's own token.")
        try keychainService.save(serverID, for: KeychainKeys.activeServerID)

        let sessionURL = preferredURL(for: server)

        let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))

        // No wipe here any more: FilterCache entries carry their own identity, so the target reads
        // its own and the source keeps its own for the way back. The wipe used to sit in the
        // container rather than a view's onChange because TabRootView is .id(activeServer.id), so
        // switching from Settings rebuilds the tab bar without instantiating HomeView and
        // Catalog/Library would hydrate from the previous server's pages. Scoped keys close that
        // hole at the source. All that is left is the size bound.
        if previousServerID != serverID {
            trimFilterCache(keeping: userID.map { CacheIdentity(serverID: serverID, userID: $0) })
        }

        // activeUserName / activeUserImageTag are global while the identity they describe is per server: re-stamp them from the target's remembered profile, else the next cold launch pairs this server's userID with the previous server's name. Cleared when the target has no remembered entry, so nothing stale outlives the switch.
        let rememberedForTarget = userID.flatMap { id in
            listRememberedUsers(serverID: serverID).first { $0.id == id }
        }
        if let rememberedForTarget {
            try? keychainService.save(rememberedForTarget.name, for: KeychainKeys.activeUserName)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserName)
        }
        if let tag = rememberedForTarget?.imageTag, !tag.isEmpty {
            try? keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }

        jellyfinClient.baseURL = sessionURL
        jellyfinClient.accessToken = token

        if let userID {
            SharedSessionMirror.write(
                serverURL: sessionURL,
                userID: userID,
                accessToken: token
            )
        } else {
            SharedSessionMirror.clear()
        }

        scheduleRouteResolve()

        // Seerr (per server+user) is left to the caller's post-switch restore path so callers can route to a picker first when userID is nil.
        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
    }

    /// Removes a server and all state scoped to it (token, password, remembered users + Seerr sessions). If it was active and others remain, promotes the most-recent survivor (restore path handles expired tokens); if none remain, clears the pointer + SharedSessionMirror so next launch lands in ServerDiscoveryView.
    func removeServer(id serverID: String) throws {
        for remembered in listRememberedUsers(serverID: serverID) {
            purgeUserCredentials(id: remembered.id, serverID: serverID)
        }

        deleteJellyfinPasswords(serverID: serverID)
        try? keychainService.delete(for: KeychainKeys.accessToken(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.userID(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.rememberedUsers(serverID: serverID))
        // The removal markers go with the server, else re-adding it later holds its profiles out again.
        try? keychainService.delete(for: KeychainKeys.forgottenUsers(serverID: serverID))
        // Every profile on the box, not just the active one: the whole server is going.
        FilterCache.shared.evict(serverID: serverID)
        profileSettings.forgetProfiles(onServer: serverID)

        let servers = listKnownServers().filter { $0.id != serverID }
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)

        if authPreferences.defaultServerID == serverID {
            authPreferences.defaultServerID = nil
        }
        // Drop this server's default-profile pin too, else re-adding the server later resurrects a pin to a profile that may be long gone.
        authPreferences.setDefaultUserID(nil, serverID: serverID)

        let activeID = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        var signalAlreadyScheduled = false
        if activeID == serverID {
            if let successor = servers.first {
                sessionNote("removed the active server, promoting \(label(for: successor)).")
                do {
                    // switchServer bumps serverDidSwitch itself; a second bump would re-key .task(id:), cancel the first probe, and double the Home reload.
                    try switchServer(to: successor.id)
                    signalAlreadyScheduled = true
                } catch {
                    // No session on the successor this device may resume. switchServer now throws before
                    // it writes anything (Sodalite#74), so the promotion moves the pointer itself: leaving
                    // it would keep the active-server entry naming the server we just deleted. The trailing
                    // bump then routes AppRouter to the successor's profile picker.
                    sessionNote("promoted \(label(for: successor)) without a session; routing to its picker.")
                    try? keychainService.save(successor.id, for: KeychainKeys.activeServerID)
                    // The stop switchServer would have done on its way through: the picker route leaves
                    // appState.activeServer standing, so activeSessionIdentity never moves and the
                    // deleted server's track would play on under the successor's picker.
                    Task { @MainActor in
                        if self.musicPlaybackCoordinator.currentItem != nil {
                            self.musicPlaybackCoordinator.stop()
                        }
                    }
                    jellyfinClient.baseURL = preferredURL(for: successor)
                    jellyfinClient.accessToken = nil
                    SharedSessionMirror.clear()
                }
            } else {
                sessionNote("removed the last server; no session left on this device.")
                try? keychainService.delete(for: KeychainKeys.activeServerID)
                jellyfinClient.baseURL = nil
                jellyfinClient.accessToken = nil
                SharedSessionMirror.clear()
            }
        }


        // Only signal when the ACTIVE server was removed; an inactive removal's bump would needlessly cancel probes + force a Home reload.
        if activeID == serverID, !signalAlreadyScheduled {
            Task { @MainActor in
                self.appState?.serverDidSwitch &+= 1
            }
        }

        // The removal has to outlive the record it deletes, so it is written down before the record
        // goes and travels on the auth record instead. Without it the first device to republish this
        // server put it straight back, and the deleting device (whose LWW stamp went with the
        // record) read its own silence as `.distantPast` and adopted the resurrection.
        if !isApplyingCloudChanges {
            authPreferences.forgottenServers[serverID] = serverSyncMetadata.nextStamp()
            cloudSync?.markServerDeleted(serverID: serverID)
        }
        serverSyncMetadata.forget(serverID: serverID)
    }

    /// Rolls the active-server pointer back after a transport-error probe failure. Named alias for switchServer (restores pointer + client + mirror, one bump) so call sites read as rollbacks.
    func rollbackSwitch(to serverID: String) throws {
        try switchServer(to: serverID)
    }

    // MARK: - Remembered Profiles

    /// All token-cached profiles for a server, most-recently-added first so fresh logins float to the top of pickers.
    func listRememberedUsers(serverID: String) -> [RememberedUser] {
        guard let data = try? keychainService.loadData(
            for: KeychainKeys.rememberedUsers(serverID: serverID)
        ) else { return [] }
        let users = (try? JSONDecoder().decode([RememberedUser].self, from: data)) ?? []
        return users.sorted { $0.addedAt > $1.addedAt }
    }

    /// Upsert, replaces any existing entry with the same user ID so
    /// re-logins refresh the token and avatar tag instead of
    /// stacking duplicates.
    func rememberUser(_ user: RememberedUser) throws {
        var users = listRememberedUsers(serverID: user.serverID)
            .filter { $0.id != user.id }
        users.append(user)
        let data = try JSONEncoder().encode(users)
        try keychainService.save(
            data,
            for: KeychainKeys.rememberedUsers(serverID: user.serverID)
        )
        // Signing in as a profile is the deliberate act that takes an earlier removal back. The entry
        // written above carries `addedAt`, which is how other devices tell this from a device that
        // has not heard about the removal yet.
        var forgotten = listForgottenUsers(serverID: user.serverID)
        forgotten.removeValue(forKey: user.id)
        setForgottenUsers(forgotten, serverID: user.serverID)
        cloudSyncMarkServer(user.serverID)
    }

    /// Profiles removed here on purpose, with the moment of removal. Published in the server record
    /// so a removal travels without the whole remembered list having to be authoritative (Sodalite#45).
    func listForgottenUsers(serverID: String) -> [String: Date] {
        guard let data = try? keychainService.loadData(for: KeychainKeys.forgottenUsers(serverID: serverID))
        else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    func setForgottenUsers(_ forgotten: [String: Date], serverID: String) {
        guard !forgotten.isEmpty else {
            try? keychainService.delete(for: KeychainKeys.forgottenUsers(serverID: serverID))
            return
        }
        guard let data = try? JSONEncoder().encode(forgotten) else { return }
        try? keychainService.save(data, for: KeychainKeys.forgottenUsers(serverID: serverID))
    }

    /// Everything scoped to one profile on one server. Shared by the local forget and the apply path,
    /// so a removal that arrives from another device leaves no credentials behind either.
    func purgeUserCredentials(id: String, serverID: String) {
        forgetRememberedSeerr(forJellyfinUserID: id, jellyfinServerID: serverID)
        try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: id))
        // Same reason: a remembered live upstream carries the IPTV provider's credentials in its path.
        liveDirectStreamMemory.forgetAll(userID: id)
        // And the entry PIN: the composite id is stable, so a profile signed in again would
        // otherwise come back holding a PIN nobody set for it.
        clearOwnPIN(for: ProfileRef(serverID: serverID, userID: id))
    }

    /// The default-server pin. Rides the server record (Sodalite#45), so both the newly pinned server
    /// and the one that lost the pin have to be republished, else the old record keeps claiming it.
    func setDefaultServer(_ serverID: String?) {
        let previous = authPreferences.defaultServerID
        guard previous != serverID else { return }
        authPreferences.defaultServerID = serverID
        if let previous { cloudSyncMarkServer(previous) }
        if let serverID { cloudSyncMarkServer(serverID) }
    }

    /// Drop one profile from a server: the remembered entry, its credentials, a default pin that
    /// named it, and a tombstone so the removal travels as a removal. Called from the pickers'
    /// long-press menu and from the reconcile against the server's user table. Leaves the active
    /// session alone (`dropActiveProfile` is the path that ends one).
    func forgetUser(id: String, serverID: String) throws {
        let remaining = listRememberedUsers(serverID: serverID)
            .filter { $0.id != id }
        if remaining.isEmpty {
            try? keychainService.delete(
                for: KeychainKeys.rememberedUsers(serverID: serverID)
            )
        } else {
            let data = try JSONEncoder().encode(remaining)
            try keychainService.save(
                data,
                for: KeychainKeys.rememberedUsers(serverID: serverID)
            )
        }
        // Record the removal, so it travels as a removal instead of as a shorter list.
        var forgotten = listForgottenUsers(serverID: serverID)
        forgotten[id] = .now
        setForgottenUsers(forgotten, serverID: serverID)
        // Drop the profile-scoped Seerr session and Jellyfin password too so a forgotten
        // user doesn't leave dangling credentials in the keychain.
        purgeUserCredentials(id: id, serverID: serverID)
        // A pin to a profile that is gone would send the next launch after a ghost. It lives here,
        // not at the call sites, so every path that removes a profile clears it (Sodalite#90).
        if authPreferences.defaultUserID(serverID: serverID) == id {
            authPreferences.setDefaultUserID(nil, serverID: serverID)
        }
        cloudSyncMarkServer(serverID)
    }

    /// Swaps to a remembered profile: reuses cached token, updates active-session keychain, reconfigures client. Drops the cached Jellyfin password unless the target profile is the one it belongs to, so Seerr auto-fill never carries another user's password but survives re-picking your own.
    func switchToUser(_ remembered: RememberedUser, server: JellyfinServer) throws {
        let previousIdentity = activeSessionIdentity()
        sessionNote("profile -> \(remembered.name) on \(label(for: server)).")
        try addServer(server)
        try keychainService.save(server.id, for: KeychainKeys.activeServerID)
        try keychainService.save(
            remembered.token,
            for: KeychainKeys.accessToken(serverID: server.id)
        )
        try keychainService.save(
            remembered.id,
            for: KeychainKeys.userID(serverID: server.id)
        )
        try keychainService.save(remembered.name, for: KeychainKeys.activeUserName)

        if let tag = remembered.imageTag, !tag.isEmpty {
            try keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }

        // Nothing to drop here: every profile's password lives under its own key, so a switch can
        // neither leak one to the next profile nor lose the one it is switching to.

        if previousIdentity?.serverID != server.id || previousIdentity?.userID != remembered.id {
            // FilterCache needs no wipe: its entries carry the identity that fetched them, so the
            // incoming profile reads its own rows, watched flags and library visibility. ImageCache
            // does, being an in-memory NSCache keyed by URL alone: a poster fetched under the
            // previous token may be unfetchable under this profile's permissions.
            ImageCache.shared.clear()
            trimFilterCache(
                keeping: CacheIdentity(serverID: server.id, userID: remembered.id)
            )
        }

        let sessionURL = preferredURL(for: server)
        jellyfinClient.baseURL = sessionURL
        jellyfinClient.accessToken = remembered.token

        SharedSessionMirror.write(
            serverURL: sessionURL,
            userID: remembered.id,
            accessToken: remembered.token
        )

        // Seerr left to the caller's restoreSeerrSession(forJellyfinUserID:jellyfinServerID:) so each profile picks up its own session, or lands on the empty state.

        cloudSyncMarkServer(server.id)
        scheduleRouteResolve()
    }

    /// Re-stamps the server's own name for a (server, user) onto both stores that cache it: the global activeUserName entry and the server's remembered profile. Called once /Users/Me has spoken, so a rename (or a name inherited from another server by an install predating the per-server name resolution) heals instead of surviving every launch.
    func persistActiveUserName(_ name: String, userID: String, serverID: String) {
        guard activeJellyfinServerID == serverID else { return }
        try? keychainService.save(name, for: KeychainKeys.activeUserName)
        guard let existing = listRememberedUsers(serverID: serverID)
            .first(where: { $0.id == userID }), existing.name != name
        else { return }
        try? rememberUser(
            RememberedUser(
                id: existing.id,
                serverID: existing.serverID,
                name: name,
                imageTag: existing.imageTag,
                token: existing.token,
                addedAt: existing.addedAt
            )
        )
    }

    /// Refreshes active-user details after a profile switch. /Users/Me supplies the Policy block (canDeleteContent gate, else stuck on the keychain stub with policy: nil) and the authoritative name; /Users/Public is the imageTag-only fallback backfilling a nil/stale RememberedUser tag. `expectedUserID` discards the result if a racing switch changed the active profile. Persists name + tag to keychain + remembered entry.
    ///
    /// It is also the first request a switched-to profile makes, which makes it the place a refused
    /// token surfaces: `.rejected` means the profile is gone from this device and the caller routes
    /// back to the picker, instead of leaving the user inside a session the server answers nothing for
    /// (Sodalite#90).
    func refreshActiveUserDetails(
        expectedUserID userID: String,
        serverID: String
    ) async -> ProfileRefresh {
        let me: JellyfinUser?
        switch await checkActiveSession() {
        case .valid(let user):
            me = user
        case .rejected(let profileName):
            return .rejected(profileName: profileName)
        case .noSession, .unreachable:
            me = nil
        }
        let directTag: String? = (me?.id == userID) ? me?.primaryImageTag : nil
        // /Users/Public fallback when directTag is nil (some Jellyfin versions only populate the tag on the public listing, not the authenticated detail endpoint).
        let fallbackTag: String? = directTag == nil ? await fetchPublicImageTag(for: userID) : nil

        // Re-read after the awaits: the active profile may have changed under this refresh.
        guard appState?.activeUser?.id == userID,
              let current = appState?.activeUser else { return .kept(nil) }

        // A refresh that could not reach the server keeps what it already had, the same way the
        // policy and the name below do (Sodalite#126). Without this, a launch that happened while
        // the server was down wrote the FAILURE into the session: nil reads as "this profile has no
        // picture", the avatar URL goes away with it, and no amount of retrying an image brings back
        // a picture the app no longer has an address for. Measured on both platforms, and the tag
        // stayed gone until the app was force-quit.
        let reachedServer = (me?.id == userID)
        let tag = reachedServer ? (directTag ?? fallbackTag) : current.primaryImageTag

        // Apply the fetched policy/name when /Users/Me succeeded; else keep the existing values (no-op, not a regression). The server owns the name, so a stale in-memory one never gets written back into the remembered entry.
        let freshPolicy = reachedServer ? me?.policy : current.policy
        let freshName = reachedServer ? (me?.name ?? current.name) : current.name
        let tagChanged = current.primaryImageTag != tag
        let policyChanged = current.policy != freshPolicy
        let nameChanged = current.name != freshName
        guard tagChanged || policyChanged || nameChanged else { return .kept(nil) }

        let fresh = JellyfinUser(
            id: current.id,
            name: freshName,
            serverID: current.serverID,
            hasPassword: current.hasPassword,
            primaryImageTag: tag,
            policy: freshPolicy
        )
        if let tag, !tag.isEmpty {
            try? keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }
        if nameChanged {
            try? keychainService.save(freshName, for: KeychainKeys.activeUserName)
        }
        if let existing = listRememberedUsers(serverID: serverID)
            .first(where: { $0.id == userID }) {
            try? rememberUser(
                RememberedUser(
                    id: existing.id,
                    serverID: existing.serverID,
                    name: fresh.name,
                    imageTag: tag,
                    token: existing.token,
                    addedAt: existing.addedAt
                )
            )
        }
        return .kept(fresh)
    }

    /// Image-tag lookup against /Users/Public for the fallback path
    /// above. Returns nil if the listing is unavailable or has no
    /// match with a non-empty tag.
    private func fetchPublicImageTag(for userID: String) async -> String? {
        if let publicUsers = try? await jellyfinAuthService.getPublicUsers(),
           let match = publicUsers.first(where: { $0.id == userID }),
           let tag = match.primaryImageTag,
           !tag.isEmpty {
            return tag
        }
        return nil
    }

    /// Adopts a password typed into the Seerr sign-in as the active profile's Jellyfin password, so
    /// the one place that asks for it again is also the place that stops having to ask.
    ///
    /// It is verified against Jellyfin first and only kept when the login comes back as the profile
    /// that is actually active. Jellyseerr may authenticate against a different Jellyfin instance
    /// than the one this session is on, and an unverified password would sit in the keychain until
    /// the token refresh path used it, failing the refresh and spending a wrong-password attempt
    /// against the server. The fresh token from that check replaces the current one, the same trade
    /// the refresh path already makes. Best effort: false means nothing was written.
    @discardableResult
    func adoptJellyfinPassword(username: String, password: String) async -> Bool {
        guard !password.isEmpty,
              let serverID = activeJellyfinServerID,
              let server = listKnownServers().first(where: { $0.id == serverID }),
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID)),
              (try? keychainService.loadString(
                  for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: userID)
              )) == nil,
              let auth = try? await jellyfinAuthService.login(username: username, password: password),
              auth.user.id == userID
        else { return false }
        try? saveSession(server: server, user: auth.user, token: auth.accessToken, password: password)
        return true
    }

    /// Every profile's password for one server, for paths that drop the server itself. Covers the
    /// active session's user too, who may not be in the remembered list yet, plus any legacy
    /// per-server entry in case migration never ran on this install.
    private func deleteJellyfinPasswords(serverID: String) {
        var userIDs = Set(listRememberedUsers(serverID: serverID).map(\.id))
        if let active = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID)) {
            userIDs.insert(active)
        }
        for userID in userIDs {
            try? keychainService.delete(
                for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: userID)
            )
        }
        try? keychainService.delete(for: KeychainKeys.legacyJellyfinPassword(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.legacyJellyfinPasswordUserID(serverID: serverID))
    }

    /// Moves a pre-per-user password onto its owner's key. The owner entry names it; without one,
    /// the old layout guarantees it belonged to the server's current user, because every profile
    /// switch deleted it. No owner and no current user leaves nothing to attribute it to, so it goes.
    func migrateLegacyJellyfinPasswords() {
        for server in listKnownServers() {
            let legacyKey = KeychainKeys.legacyJellyfinPassword(serverID: server.id)
            guard let password = try? keychainService.loadString(for: legacyKey), !password.isEmpty else {
                try? keychainService.delete(for: KeychainKeys.legacyJellyfinPasswordUserID(serverID: server.id))
                continue
            }
            let owner = (try? keychainService.loadString(
                for: KeychainKeys.legacyJellyfinPasswordUserID(serverID: server.id)
            )) ?? (try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)))

            if let owner {
                try? keychainService.save(
                    password,
                    for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: owner)
                )
            }
            try? keychainService.delete(for: legacyKey)
            try? keychainService.delete(for: KeychainKeys.legacyJellyfinPasswordUserID(serverID: server.id))
        }
    }

    /// The active profile's password, nil when that profile never signed in with one.
    func loadJellyfinPassword() -> String? {
        guard let server = activeJellyfinServerID,
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server))
        else { return nil }
        return try? keychainService.loadString(
            for: KeychainKeys.jellyfinPassword(serverID: server, userID: userID)
        )
    }

    private var activeJellyfinServerID: String? {
        try? keychainService.loadString(for: KeychainKeys.activeServerID)
    }

    func clearSession() throws {
        // Full logout is local-only per spec; disabling cloud sync first means the
        // per-server deletes below never mark (else a device-local logout would
        // propagate as a server deletion to every other synced device).
        cloudSync?.handleFullLogout()

        // Full logout: scrub every server's per-server entries, then the multi-server pointers + global active-user keys + client state + SharedSessionMirror.
        // Own PINs go too: the Guardian PIN and the lock roles stay, so a profile signed in again
        // falls back to the Guardian PIN, which is more locked, never less.
        for known in listKnownServers() {
            for remembered in listRememberedUsers(serverID: known.id) {
                purgeUserCredentials(id: remembered.id, serverID: known.id)
            }
            deleteJellyfinPasswords(serverID: known.id)
            try? keychainService.delete(for: KeychainKeys.accessToken(serverID: known.id))
            try? keychainService.delete(for: KeychainKeys.userID(serverID: known.id))
            try? keychainService.delete(for: KeychainKeys.rememberedUsers(serverID: known.id))
            try? keychainService.delete(for: KeychainKeys.forgottenUsers(serverID: known.id))
        }

        try? keychainService.delete(for: KeychainKeys.knownServers)
        try? keychainService.delete(for: KeychainKeys.activeServerID)
        try? keychainService.delete(for: KeychainKeys.activeUserName)
        try? keychainService.delete(for: KeychainKeys.activeUserImageTag)

        jellyfinClient.baseURL = nil
        jellyfinClient.accessToken = nil

        SharedSessionMirror.clearAll()

        try clearSeerrSession()
    }

    // MARK: - Parental Controls / Guardian-PIN

    private struct GuardianPINThrottle: Codable {
        var failedAttempts: Int = 0
        /// Unix epoch seconds the lockout expires; nil = not locked.
        var lockoutUntil: TimeInterval?
    }

    enum PINVerifyResult: Equatable {
        case success
        /// Wrong PIN; `remainingBeforeLockout` attempts left in this round.
        case wrong(remainingBeforeLockout: Int)
        /// Too many failures; locked until `until`.
        case lockedOut(until: Date)
    }

    /// Attempts before the first lockout, and the base lockout duration.
    private static let pinMaxAttempts = 5
    private static let pinBaseLockout: TimeInterval = 60
    private static let pinMaxLockout: TimeInterval = 3600

    func isGuardianPINSet() -> Bool {
        (try? keychainService.loadData(for: KeychainKeys.guardianPINBlob)) != nil
    }

    func saveGuardianPIN(_ pin: String) throws {
        let blob = GuardianPINCrypto.makeBlob(pin: pin)
        let data = try JSONEncoder().encode(blob)
        try keychainService.save(data, for: KeychainKeys.guardianPINBlob)
        // A freshly set PIN starts with a clean slate.
        try? keychainService.delete(for: throttleKey(for: .guardian))
        try? keychainService.delete(for: KeychainKeys.guardianPINProfileDoorThrottle)
        if !isApplyingCloudChanges { cloudSync?.markSecurityDirty() }
    }

    func clearGuardianPIN() throws {
        // Every own PIN exists only underneath a Guardian PIN, so switching the Guardian PIN off
        // takes them with it. Here rather than at the call sites, so neither the settings switch nor
        // a remote record deletion has to remember. Inline rather than through clearOwnPIN, which
        // would raise one sync mark per profile on top of the deletion already being published.
        for ref in profilesWithOwnPIN() {
            try? keychainService.delete(for: blobKey(for: .profile(ref)))
            try? keychainService.delete(for: throttleKey(for: .profile(ref)))
        }
        try keychainService.delete(for: KeychainKeys.guardianPINBlob)
        try? keychainService.delete(for: KeychainKeys.guardianPINThrottle)
        try? keychainService.delete(for: KeychainKeys.guardianPINProfileDoorThrottle)
        if !isApplyingCloudChanges { cloudSync?.markSecurityDeleted() }
    }

    // MARK: Doors

    private func blobKey(for door: PINDoor) -> String {
        switch door {
        case .guardian: KeychainKeys.guardianPINBlob
        case .profile(let ref): KeychainKeys.profilePINBlob(serverID: ref.serverID, userID: ref.userID)
        }
    }

    private func throttleKey(for door: PINDoor) -> String {
        switch door {
        case .guardian: KeychainKeys.guardianPINThrottle
        case .profile(let ref): KeychainKeys.profilePINThrottle(serverID: ref.serverID, userID: ref.userID)
        }
    }

    private func loadBlob(for door: PINDoor) -> GuardianPINCrypto.Blob? {
        guard let data = try? keychainService.loadData(for: blobKey(for: door)) else { return nil }
        return try? JSONDecoder().decode(GuardianPINCrypto.Blob.self, from: data)
    }

    func hasOwnPIN(_ ref: ProfileRef) -> Bool {
        (try? keychainService.loadData(for: blobKey(for: .profile(ref)))) != nil
    }

    /// Every profile on this device that carries an own PIN. The keychain is the only record of
    /// that: a second index in UserDefaults would drift, and a wiped defaults domain would leave a
    /// live secret invisible.
    func profilesWithOwnPIN() -> [ProfileRef] {
        var found: [ProfileRef] = []
        for server in listKnownServers() {
            for user in listRememberedUsers(serverID: server.id) {
                let ref = ProfileRef(serverID: server.id, userID: user.id)
                if hasOwnPIN(ref) { found.append(ref) }
            }
        }
        return found
    }

    func saveOwnPIN(_ pin: String, for ref: ProfileRef) throws {
        let blob = GuardianPINCrypto.makeBlob(pin: pin)
        try keychainService.save(try JSONEncoder().encode(blob), for: blobKey(for: .profile(ref)))
        try? keychainService.delete(for: throttleKey(for: .profile(ref)))
        if !isApplyingCloudChanges { cloudSync?.markSecurityDirty() }
    }

    func clearOwnPIN(for ref: ProfileRef) {
        guard hasOwnPIN(ref) else { return }
        try? keychainService.delete(for: blobKey(for: .profile(ref)))
        try? keychainService.delete(for: throttleKey(for: .profile(ref)))
        if !isApplyingCloudChanges { cloudSync?.markSecurityDirty() }
    }

    /// True when `pin` already opens some other door. An own PIN that repeats the Guardian PIN, or
    /// another profile's, rebuilds the exact leak per-profile PINs exist to close, and nothing later
    /// would reveal it. `excluding` is nil while collecting a new Guardian PIN, where matching the
    /// Guardian PIN's own previous value is simply a no-op change.
    func pinCollides(_ pin: String, excluding ref: ProfileRef?) -> Bool {
        if ref != nil, let guardianBlob = loadBlob(for: .guardian),
           GuardianPINCrypto.verify(pin: pin, blob: guardianBlob) {
            return true
        }
        for other in profilesWithOwnPIN() where other != ref {
            if let blob = loadBlob(for: .profile(other)),
               GuardianPINCrypto.verify(pin: pin, blob: blob) {
                return true
            }
        }
        return false
    }

    private func loadThrottle(key: String) -> GuardianPINThrottle {
        guard let data = try? keychainService.loadData(for: key),
              let throttle = try? JSONDecoder().decode(GuardianPINThrottle.self, from: data)
        else { return GuardianPINThrottle() }
        return throttle
    }

    private func saveThrottle(_ throttle: GuardianPINThrottle, key: String) {
        if let data = try? JSONEncoder().encode(throttle) {
            try? keychainService.save(data, for: key)
        }
    }

    private func activeLockout(key: String) -> Date? {
        guard let until = loadThrottle(key: key).lockoutUntil else { return nil }
        let date = Date(timeIntervalSince1970: until)
        return date > Date() ? date : nil
    }

    /// One more miss on a throttle: after pinMaxAttempts in a row the lockout starts at
    /// pinBaseLockout and doubles with every further miss, capped at pinMaxLockout.
    @discardableResult
    private func recordMiss(key: String) -> PINVerifyResult {
        var updated = loadThrottle(key: key)
        updated.failedAttempts += 1
        guard updated.failedAttempts >= Self.pinMaxAttempts else {
            saveThrottle(updated, key: key)
            return .wrong(remainingBeforeLockout: Self.pinMaxAttempts - updated.failedAttempts)
        }
        let rounds = updated.failedAttempts - Self.pinMaxAttempts
        let duration = min(Self.pinMaxLockout, Self.pinBaseLockout * pow(2, Double(rounds)))
        let until = Date().timeIntervalSince1970 + duration
        updated.lockoutUntil = until
        saveThrottle(updated, key: key)
        return .lockedOut(until: Date(timeIntervalSince1970: until))
    }

    /// Current lockout deadline for one door if one is active and still in the future. A profile
    /// door without an own PIN has only the Guardian PIN as its key, so the shared profile-door
    /// budget for the Guardian PIN locks it too.
    func pinLockout(for door: PINDoor) -> Date? {
        let own = activeLockout(key: throttleKey(for: door))
        guard case .profile(let ref) = door, !hasOwnPIN(ref),
              let shared = activeLockout(key: KeychainKeys.guardianPINProfileDoorThrottle)
        else { return own }
        return max(own ?? shared, shared)
    }

    func guardianPINLockout() -> Date? { pinLockout(for: .guardian) }

    func verifyGuardianPIN(_ pin: String) -> PINVerifyResult { verifyPIN(pin, for: .guardian) }

    /// A profile door takes that profile's own PIN or the Guardian PIN; the Guardian door takes only
    /// its own. A profile with no own blob falls through to the Guardian PIN, which is the safe
    /// direction if the keychain and the roles ever drift.
    ///
    /// Each door counts its own misses, and the Guardian PIN typed at any profile door also counts
    /// against one budget shared by all of them: with a counter per door, k entry-locked profiles
    /// gave a guesser k extra budgets on the Guardian PIN (audit 2026-09-25 CS-7). The Guardian
    /// door keeps its own counter, so guessing at a profile never locks the parent out of Settings.
    func verifyPIN(_ pin: String, for door: PINDoor) -> PINVerifyResult {
        if let until = activeLockout(key: throttleKey(for: door)) { return .lockedOut(until: until) }

        guard case .profile = door else {
            // No blob anywhere is a failure, never a pass: gate decisions already require
            // isGuardianPINSet, and a missing blob must not become an open door.
            if let guardianBlob = loadBlob(for: .guardian),
               GuardianPINCrypto.verify(pin: pin, blob: guardianBlob) {
                try? keychainService.delete(for: throttleKey(for: door))
                return .success
            }
            return recordMiss(key: throttleKey(for: door))
        }

        let own = loadBlob(for: door)
        let sharedKey = KeychainKeys.guardianPINProfileDoorThrottle
        let sharedLockout = activeLockout(key: sharedKey)
        if own == nil, let sharedLockout { return .lockedOut(until: sharedLockout) }

        if let own, GuardianPINCrypto.verify(pin: pin, blob: own) {
            try? keychainService.delete(for: throttleKey(for: door))
            return .success
        }
        let guardianBlob = sharedLockout == nil ? loadBlob(for: .guardian) : nil
        if let guardianBlob, GuardianPINCrypto.verify(pin: pin, blob: guardianBlob) {
            // Whoever just proved they hold the Guardian PIN should not stay part-way to a lockout
            // on any of its counters either.
            try? keychainService.delete(for: throttleKey(for: door))
            try? keychainService.delete(for: sharedKey)
            try? keychainService.delete(for: KeychainKeys.guardianPINThrottle)
            return .success
        }

        let doorResult = recordMiss(key: throttleKey(for: door))
        guard guardianBlob != nil else { return doorResult }
        let sharedResult = recordMiss(key: sharedKey)
        // Without an own PIN the Guardian PIN is this door's only key, so its budget is the door's.
        guard own == nil else { return doorResult }
        switch (doorResult, sharedResult) {
        case (.lockedOut, _): return doorResult
        case (_, .lockedOut): return sharedResult
        case let (.wrong(door), .wrong(shared)): return .wrong(remainingBeforeLockout: min(door, shared))
        default: return doorResult
        }
    }

    // MARK: Gate decisions

    /// Parental controls are engaged when a PIN is set AND at least one
    /// remembered profile (on any known server) carries a lock role.
    func parentalControlsActive() -> Bool {
        guard isGuardianPINSet() else { return false }
        return parentalControlsPreferences.hasAnyLockedProfile
    }

    /// The (serverID, userID) of the active session, read from the
    /// keychain pointers so this works before AppState is populated.
    private func activeSessionIdentity() -> CacheIdentity? {
        guard let serverID = try? keychainService.loadString(for: KeychainKeys.activeServerID),
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))
        else { return nil }
        return CacheIdentity(serverID: serverID, userID: userID)
    }

    /// The profile the session is signed in as, from the keychain pointers every switch writes
    /// before AppState follows. Capture it before an await and hand it to `isActiveProfile` after.
    func activeProfileRef() -> ProfileRef? {
        activeSessionIdentity().map { ProfileRef(serverID: $0.serverID, userID: $0.userID) }
    }

    /// Whether `ref` is still the active profile. Anything acting on a session after an await asks
    /// this first: a same-server profile switch raises no signal a task could be cancelled by.
    func isActiveProfile(_ ref: ProfileRef?) -> Bool {
        activeProfileRef() == ref
    }

    /// The lock role of the active session, or `.open` when there is no session yet.
    private func activeProfileRole() -> ProfileLockRole {
        guard let ref = activeProfileRef() else { return .open }
        return parentalControlsPreferences.role(ref)
    }

    /// Whether activating the given target profile needs the Guardian-PIN. The judgement itself
    /// lives in `ParentalGatePolicy`; this resolves the two roles it decides on.
    func parentalGateRequired(forActivatingUserID userID: String, serverID: String) -> Bool {
        guard parentalControlsActive() else { return false }
        return ParentalGatePolicy.gateRequiredForActivating(
            targetRole: parentalControlsPreferences.role(serverID: serverID, userID: userID),
            activeRole: activeProfileRole()
        )
    }

    /// The one way a lock role changes. A role that is not `pinToEnter` has no entry door, so its
    /// own PIN would be a secret nothing consults and a profile signed in again silently inherits.
    func setLockRole(_ role: ProfileLockRole, for ref: ProfileRef) {
        parentalControlsPreferences.setRole(role, for: ref)
        if role != .pinToEnter { clearOwnPIN(for: ref) }
    }

    /// Which prompt the PIN pad shows for this activation, and which door it stands at.
    func parentalGateReason(forActivatingUserID userID: String, serverID: String) -> PINReason {
        let ref = ProfileRef(serverID: serverID, userID: userID)
        return ParentalGatePolicy.reason(forActivating: parentalControlsPreferences.role(ref), ref: ref)
    }

    /// The one place a challenge's key is chosen. Call sites pass the reason they were handed and
    /// never reach for a blob themselves.
    func verifyPIN(_ pin: String, for reason: PINReason) -> PINVerifyResult {
        verifyPIN(pin, for: ParentalGatePolicy.door(for: reason))
    }

    func pinLockout(for reason: PINReason) -> Date? {
        pinLockout(for: ParentalGatePolicy.door(for: reason))
    }

    /// Whether a session-scoped escape action (logout, server management,
    /// switching server from the picker) needs the PIN.
    func parentalGateRequiredForSessionAction() -> Bool {
        guard parentalControlsActive() else { return false }
        return ParentalGatePolicy.sessionActionRequiresPIN(
            activeRole: activeProfileRole(),
            activeHasOwnPIN: activeProfileRef().map { hasOwnPIN($0) } ?? false
        )
    }

    /// One-shot: before #105 an unmarked profile still cost the PIN to enter at a cold start, and
    /// "unmarked" is what the new model calls open, which costs nothing. So an install that had
    /// parental controls configured has its unmarked profiles read as what they behaved like,
    /// pinToEnter. Without this the upgrade would silently unlock every adult profile on the device.
    /// Latched in UserDefaults, and it never runs on an install that had no lock to migrate.
    func migrateUnmarkedProfilesToEntryLocked() {
        let latch = "parental.entryLockMigrationDone"
        guard !UserDefaults.standard.bool(forKey: latch) else { return }
        UserDefaults.standard.set(true, forKey: latch)
        guard isGuardianPINSet(), !parentalControlsPreferences.protectedProfileIDs.isEmpty else { return }
        for server in listKnownServers() {
            for user in listRememberedUsers(serverID: server.id)
            where parentalControlsPreferences.role(serverID: server.id, userID: user.id) == .open {
                parentalControlsPreferences.setRole(.pinToEnter, serverID: server.id, userID: user.id)
            }
        }
    }

    /// See `restoreSession()` for the rationale behind silent `try?` here.
    func restoreSeerrSession() -> SeerrServer? {
        guard let serverData = try? keychainService.loadData(for: KeychainKeys.seerrServer),
              let server = try? JSONDecoder().decode(SeerrServer.self, from: serverData),
              let cookie = try? keychainService.loadString(for: KeychainKeys.seerrSession(serverID: server.id))
        else {
            return nil
        }

        seerrClient.baseURL = preferredSeerrURL(for: server)
        seerrClient.sessionCookie = cookie
        return server
    }

    /// The Seerr server currently stored for a profile (else the legacy global entry), so a re-sign-in
    /// can keep the URL slot it does not carry.
    private func storedSeerrServer(
        forJellyfinUserID jellyfinUserID: String?,
        jellyfinServerID: String?
    ) -> SeerrServer? {
        if let jellyfinUserID, let jellyfinServerID,
           let data = try? keychainService.loadData(for: KeychainKeys.rememberedSeerr(
               jellyfinServerID: jellyfinServerID, jellyfinUserID: jellyfinUserID)),
           let remembered = try? JSONDecoder().decode(RememberedSeerrSession.self, from: data) {
            return remembered.seerrServer
        }
        guard let data = try? keychainService.loadData(for: KeychainKeys.seerrServer) else { return nil }
        return try? JSONDecoder().decode(SeerrServer.self, from: data)
    }

    /// Returns the server as persisted, which may carry a URL slot the caller did not know about.
    @discardableResult
    func saveSeerrSession(
        server rediscovered: SeerrServer,
        forJellyfinUserID jellyfinUserID: String? = nil,
        jellyfinServerID: String? = nil
    ) throws -> SeerrServer {
        // Same slot retention as addServer (Sodalite#45): the Seerr sign-in classifies the one
        // address it was given, so signing in again must not drop the other slot and sync the loss.
        let server = storedSeerrServer(
            forJellyfinUserID: jellyfinUserID,
            jellyfinServerID: jellyfinServerID
        ).map { rediscovered.fillingEmptyURLSlots(fromKnown: $0) } ?? rediscovered
        seerrClient.baseURL = preferredSeerrURL(for: server)

        if let jellyfinUserID, let jellyfinServerID, let cookie = seerrClient.sessionCookie {
            // Profile-scoped persistence. The global (pre-0.3.0) entry is NOT refreshed here: rewriting it kept the legacy fallback live and let a scopeless profile inherit whoever last logged in. Global keys are read-only legacy now (see syncSeerrSession).
            let remembered = RememberedSeerrSession(
                jellyfinUserID: jellyfinUserID,
                jellyfinServerID: jellyfinServerID,
                seerrServer: server,
                cookie: cookie
            )
            let data = try JSONEncoder().encode(remembered)
            try keychainService.save(
                data,
                for: KeychainKeys.rememberedSeerr(
                    jellyfinServerID: jellyfinServerID,
                    jellyfinUserID: jellyfinUserID
                )
            )
            cloudSyncMarkServer(jellyfinServerID)
        } else if jellyfinUserID == nil || jellyfinServerID == nil {
            // Login outside any Jellyfin-user context: the global entry is the only place to persist. Not reached when a profile context exists (that would refresh the deprecated legacy entry).
            let serverData = try JSONEncoder().encode(server)
            try keychainService.save(serverData, for: KeychainKeys.seerrServer)
            if let cookie = seerrClient.sessionCookie {
                try keychainService.save(cookie, for: KeychainKeys.seerrSession(serverID: server.id))
            }
        }
        scheduleRouteResolve()
        return server
    }

    /// Rewrites the connected Seerr server's URL slots (iOS edit sheet):
    /// updates the profile-scoped remembered session (keeping the cookie),
    /// mirrors to cloud sync, refreshes AppState, and re-resolves the route.
    func updateSeerrServerURLs(internalURL: URL?, externalURL: URL?) throws {
        guard internalURL != nil || externalURL != nil,
              let current = appState?.activeSeerrServer else { return }
        let updated = SeerrServer(id: current.id, internalURL: internalURL, externalURL: externalURL)

        if let userID = activeUserID, let serverID = activeServer?.id {
            let key = KeychainKeys.rememberedSeerr(jellyfinServerID: serverID, jellyfinUserID: userID)
            if let data = try? keychainService.loadData(for: key),
               let remembered = try? JSONDecoder().decode(RememberedSeerrSession.self, from: data) {
                let rewritten = RememberedSeerrSession(
                    jellyfinUserID: remembered.jellyfinUserID,
                    jellyfinServerID: remembered.jellyfinServerID,
                    seerrServer: updated,
                    cookie: remembered.cookie
                )
                try keychainService.save(JSONEncoder().encode(rewritten), for: key)
                cloudSyncMarkServer(serverID)
            }
        }

        // Legacy global entry (pre-0.3.0 fallback): keep it in step when it points at the same server.
        if let data = try? keychainService.loadData(for: KeychainKeys.seerrServer),
           let globalServer = try? JSONDecoder().decode(SeerrServer.self, from: data),
           globalServer.id == updated.id {
            try? keychainService.save(JSONEncoder().encode(updated), for: KeychainKeys.seerrServer)
        }

        seerrClient.baseURL = preferredSeerrURL(for: updated)
        appState?.updateActiveSeerrServer(updated)
        scheduleRouteResolve()
    }

    /// Restores a specific profile's Seerr session. Returns the SeerrServer so the caller can probe currentUser(); nil when the profile has none (caller clears Seerr state).
    func restoreSeerrSession(
        forJellyfinUserID jellyfinUserID: String,
        jellyfinServerID: String
    ) -> SeerrServer? {
        let key = KeychainKeys.rememberedSeerr(
            jellyfinServerID: jellyfinServerID,
            jellyfinUserID: jellyfinUserID
        )
        guard let data = try? keychainService.loadData(for: key),
              let remembered = try? JSONDecoder().decode(RememberedSeerrSession.self, from: data)
        else {
            return nil
        }
        seerrClient.baseURL = preferredSeerrURL(for: remembered.seerrServer)
        seerrClient.sessionCookie = remembered.cookie
        return remembered.seerrServer
    }

    /// Per-profile Seerr forget, used when a stored Seerr session
    /// fails to restore (server rotated, cookie expired, user
    /// revoked). Leaves other profiles' sessions alone.
    func forgetRememberedSeerr(forJellyfinUserID jellyfinUserID: String, jellyfinServerID: String) {
        try? keychainService.delete(
            for: KeychainKeys.rememberedSeerr(
                jellyfinServerID: jellyfinServerID,
                jellyfinUserID: jellyfinUserID
            )
        )
        cloudSyncMarkServer(jellyfinServerID)
    }

    /// Drops the in-memory Seerr identity without touching keychain. Used on tvOS-user change: the previous user's persisted session must survive, but the live client must stop acting as them immediately.
    func detachSeerrClient() {
        seerrClient.baseURL = nil
        seerrClient.sessionCookie = nil
    }

    func clearSeerrSession() throws {
        if let serverData = try? keychainService.loadData(for: KeychainKeys.seerrServer),
           let decoded = try? JSONDecoder().decode(SeerrServer.self, from: serverData) {
            try keychainService.delete(for: KeychainKeys.seerrSession(serverID: decoded.id))
        }
        try keychainService.delete(for: KeychainKeys.seerrServer)

        seerrClient.baseURL = nil
        seerrClient.sessionCookie = nil
    }

    /// Single owner of the Seerr "restore → probe /auth/me → keep or drop" policy; every restore path maps the outcome onto AppState. Entry dropped only on 401/403 (RememberedSeerrSession contract); transport failures keep it so the session returns next launch.
    func syncSeerrSession(
        forJellyfinUserID jellyfinUserID: String?,
        jellyfinServerID: String?,
        allowLegacyFallback: Bool = false
    ) async -> SeerrSyncOutcome {
        seerrSyncGeneration &+= 1
        let generation = seerrSyncGeneration
        let scopedServer: SeerrServer? = {
            guard let jellyfinUserID, let jellyfinServerID else { return nil }
            return restoreSeerrSession(
                forJellyfinUserID: jellyfinUserID,
                jellyfinServerID: jellyfinServerID
            )
        }()

        // Legacy global fallback (pre-0.3.0) so old installs return on first upgrade. Only when the profile has no scoped entry.
        let server = scopedServer ?? (allowLegacyFallback ? restoreSeerrSession() : nil)

        guard let server else {
            // No remembered session anywhere: clear any stale client/global state from a previous profile.
            try? clearSeerrSession()
            return .notConfigured
        }

        do {
            let user = try await seerrAuthService.currentUser()

            // Legacy bridge: persist a globally-restored session as a scoped copy, then retire the global entry (else a DIFFERENT scopeless profile inherits this cookie at a later cold launch).
            if scopedServer == nil, let jellyfinUserID, let jellyfinServerID {
                let bridged = try? saveSeerrSession(
                    server: server,
                    forJellyfinUserID: jellyfinUserID,
                    jellyfinServerID: jellyfinServerID
                )
                // Retire the global entry only once the scoped copy exists; a failed write plus an unconditional delete drops the session entirely.
                if bridged != nil {
                    try? keychainService.delete(for: KeychainKeys.seerrSession(serverID: server.id))
                    try? keychainService.delete(for: KeychainKeys.seerrServer)
                }
            }
            return .connected(server: server, user: user)
        } catch let error as APIError where error.isUnauthorized {
            // Cookie rejected: drop the entry (scoped copy only when that was probed, leaving other profiles untouched).
            if scopedServer != nil, let jellyfinUserID, let jellyfinServerID {
                forgetRememberedSeerr(
                    forJellyfinUserID: jellyfinUserID,
                    jellyfinServerID: jellyfinServerID
                )
            }
            // A newer sync has pointed the live client at the next profile's session by now.
            if generation == seerrSyncGeneration { try? clearSeerrSession() }
            return .invalidated
        } catch {
            // Timeout / unreachable / cancellation: NOT a verdict on the cookie. Keep the entry + client configured, just don't mark connected.
            return .transientFailure
        }
    }

    /// `syncSeerrSession` plus the AppState mapping every caller shares, applied only while the
    /// profile it ran for is still the active one and no newer sync overtook it. A switch inside
    /// the Seerr round trip (up to its 30 s timeout, Sodalite#122) otherwise landed the previous
    /// profile's Seerr user, or its failure, on the profile switched to.
    ///
    /// `disconnectUnlessConnected` is false for the launch and outage passes, which only ever add
    /// a connection they learned late.
    func applySeerrSession(
        forJellyfinUserID jellyfinUserID: String?,
        jellyfinServerID: String?,
        allowLegacyFallback: Bool = false,
        disconnectUnlessConnected: Bool = true,
        keepsSessionOnTransientFailure: Bool = false
    ) async {
        let profile = activeProfileRef()
        if let jellyfinUserID, let jellyfinServerID,
           profile != ProfileRef(serverID: jellyfinServerID, userID: jellyfinUserID) {
            return
        }
        // The sync bumps the generation before its first await, so this is the value it runs under.
        let generation = seerrSyncGeneration &+ 1
        let outcome = await syncSeerrSession(
            forJellyfinUserID: jellyfinUserID,
            jellyfinServerID: jellyfinServerID,
            allowLegacyFallback: allowLegacyFallback
        )
        guard generation == seerrSyncGeneration, isActiveProfile(profile) else { return }
        switch outcome {
        case .connected(let server, let user):
            appState?.setSeerrConnected(server: server, user: user)
            scheduleRouteResolve()
        case .transientFailure where keepsSessionOnTransientFailure:
            break
        default:
            if disconnectUnlessConnected { appState?.disconnectSeerr() }
        }
    }
}

/// Result of `syncSeerrSession`. Callers map this onto AppState:
/// `.connected` → `setSeerrConnected`, everything else →
/// `disconnectSeerr()` (the keychain handling already happened
/// inside the container).
enum SeerrSyncOutcome {
    case connected(server: SeerrServer, user: SeerrUser)
    /// No remembered session for this profile.
    case notConfigured
    /// Server rejected the stored cookie; entry was forgotten.
    case invalidated
    /// Transport failure; entry kept for a later retry.
    case transientFailure
}
