import Foundation

extension DependencyContainer {
    /// Recomputes who takes part in a combined Home. Cheap when nothing changed: the registry keeps
    /// its sessions and its revision (Sodalite#85).
    func refreshSessionRegistry() {
        let server = activeServer
        let userID = activeUserID
        let scope = server.flatMap { server in userID.map { ProfileKey(serverID: server.id, userID: $0).storageScope } }
        let candidates = ParticipantPlanner.plan(
            servers: listKnownServers(),
            activeServerID: server?.id,
            enabled: scope.map { combinedServers.isEnabled(scope: $0) } ?? false,
            excluded: scope.map { combinedServers.excludedServerIDs(scope: $0) } ?? [],
            lastActivated: serverActivation.all(),
            credential: { secondaryCredential(serverID: $0) }
        )
        sessionRegistry.apply(
            active: server.flatMap { server in userID.map { (server, $0) } },
            secondaries: candidates,
            baseURL: { preferredURL(for: $0) }
        )
        // A secondary built just now holds its token until a pass has probed it (audit NET-201).
        if sessionRegistry.participants.contains(where: { !$0.isActive && $0.client.routeGate?.isSettled == false }) {
            scheduleRouteResolve()
        }
        // Also when nothing changed: a logout cleared the slot, and the registry only reports change.
        SharedSessionMirror.writeParticipants(sessionRegistry.shelfParticipants)
        downloadManager?.serversChanged()
        Task { [sessionRegistry] in
            for session in sessionRegistry.participants { await session.loadUserIfNeeded() }
        }
    }

    /// Points each secondary at whichever of its addresses answers, as `resolveJellyfinRoute` does
    /// for the active one, all at once: each one waits on its own slowest slot only.
    func resolveSecondaryRoutes(generation: UInt64) async {
        let secondaries = sessionRegistry.participants.filter { !$0.isActive && $0.server != nil }
        await withTaskGroup(of: Void.self) { group in
            for session in secondaries {
                group.addTask { await self.resolveSecondaryRoute(session, generation: generation) }
            }
        }
        guard isCurrentRoutePass(generation) else { return }
        // A secondary whose address just proved itself can join the Top Shelf (Sodalite#218).
        SharedSessionMirror.writeParticipants(sessionRegistry.shelfParticipants)
        downloadManager?.serversChanged()
    }

    private func resolveSecondaryRoute(_ session: ServerSession, generation: UInt64) async {
        guard let server = session.server else { return }
        let gate = session.client.routeGate
        let epoch = gate?.epoch ?? 0
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: verifyingProbe(serverID: server.id, gate: gate, epoch: epoch)
        ) else {
            gate?.settle(epoch: epoch)
            return
        }
        guard isCurrentRoutePass(generation) else { return }
        serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
        sessionRegistry.updateRoute(resolved.url, for: session)
        await proveIfStillUnproved(resolved.url, serverID: server.id, gate: gate, epoch: epoch)
        guard isCurrentRoutePass(generation) else { return }
        gate?.settle(epoch: epoch)
        await session.loadUserIfNeeded()
    }
}

extension DependencyContainer {
    /// Home's sources, active first. The active one uses the caller's user id, which is what
    /// `AppState.activeUser` holds, so a single-server Home keeps its exact identity.
    func homeSources(activeUserID: String) -> [HomeSource] {
        sessionRegistry.participants.map { session in
            HomeSource(
                serverID: session.server?.id ?? activeUserID,
                serverName: session.server?.name ?? "",
                userID: session.isActive ? activeUserID : session.userID,
                libraryService: session.libraryService,
                isActive: session.isActive
            )
        }
    }
}

extension DependencyContainer {
    enum CombinedServerStatus: Equatable {
        case active
        case contributes(userName: String)
        case excluded(userName: String)
        case noSession
    }

    private var combineScope: String? {
        guard let server = activeServer, let userID = activeUserID else { return nil }
        return ProfileKey(serverID: server.id, userID: userID).storageScope
    }

    func isCombiningServers() -> Bool {
        combineScope.map { combinedServers.isEnabled(scope: $0) } ?? false
    }

    /// The one way the switch changes: Home reloads and the profile's home record uploads off the
    /// same notification Customize posts.
    func setCombiningServers(_ enabled: Bool) {
        guard let scope = combineScope else { return }
        combinedServers.setEnabled(enabled, scope: scope)
        refreshSessionRegistry()
        NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
    }

    func setServer(_ serverID: String, combined: Bool) {
        guard let scope = combineScope else { return }
        var excluded = combinedServers.excludedServerIDs(scope: scope)
        if combined { excluded.remove(serverID) } else { excluded.insert(serverID) }
        combinedServers.setExcluded(excluded, scope: scope)
        refreshSessionRegistry()
        NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
    }

    func rememberedLiveTVServerID() -> String? {
        combineScope.flatMap { combinedServers.liveTVServerID(scope: $0) }
    }

    func rememberLiveTVServer(_ serverID: String) {
        guard let scope = combineScope else { return }
        combinedServers.setLiveTVServerID(serverID, scope: scope)
    }

    func rememberedMusicServerID() -> String? {
        combineScope.flatMap { combinedServers.musicServerID(scope: $0) }
    }

    func rememberMusicServer(_ serverID: String) {
        guard let scope = combineScope else { return }
        combinedServers.setMusicServerID(serverID, scope: scope)
    }

    func combinedServerStatus(_ server: JellyfinServer) -> CombinedServerStatus {
        if server.id == activeServer?.id { return .active }
        guard let credential = secondaryCredential(serverID: server.id) else { return .noSession }
        let name = listRememberedUsers(serverID: server.id).first { $0.id == credential.userID }?.name ?? ""
        let excluded = combineScope.map { combinedServers.excludedServerIDs(scope: $0).contains(server.id) } ?? false
        return excluded ? .excluded(userName: name) : .contributes(userName: name)
    }
}

extension DependencyContainer {
    /// Search's sources, active first, read when a search tab opens and refreshed on a revision.
    func searchSources(activeUserID: String) -> [SearchSource] {
        sessionRegistry.participants.map { session in
            SearchSource(
                serverID: session.server?.id ?? "",
                userID: session.isActive ? activeUserID : session.userID,
                itemService: session.itemService,
                isActive: session.isActive
            )
        }
    }

    /// Live TV's sources, active first.
    func liveTVSources(activeUserID: String) -> [LiveTVSource] {
        sessionRegistry.participants.map { session in
            LiveTVSource(
                serverID: session.server?.id ?? "",
                serverName: session.server?.name ?? "",
                userID: session.isActive ? activeUserID : session.userID,
                liveTvService: session.liveTvService,
                playbackService: session.playbackService,
                itemService: session.itemService,
                isActive: session.isActive
            )
        }
    }

    /// Gates the Live TV tab: the participants exposing any Live TV channel. Empty on any error.
    func liveTVServerIDs(activeUserID: String, previouslyCapable: Set<String> = []) async -> [String] {
        await LiveTVProbe.capableServerIDs(
            liveTVSources(activeUserID: activeUserID), secondaryDeadline: .seconds(4),
            previouslyCapable: previouslyCapable)
    }
}

extension DependencyContainer {
    /// Music's sources, active first (Sodalite#85).
    func musicSources(activeUserID: String) -> [MusicSource] {
        sessionRegistry.participants.map { session in
            MusicSource(
                serverID: session.server?.id ?? "",
                serverName: session.server?.name ?? "",
                userID: session.isActive ? activeUserID : session.userID,
                musicService: session.musicService,
                isActive: session.isActive
            )
        }
    }

    /// Gates the Music tab: the participants with a music library. Empty on any error.
    func musicServerIDs(activeUserID: String, previouslyCapable: Set<String> = []) async -> [String] {
        await MusicProbe.capableServerIDs(
            musicSources(activeUserID: activeUserID), secondaryDeadline: .seconds(4),
            previouslyCapable: previouslyCapable)
    }

    /// The service and user an album's or a track's own server answers with; the active profile's
    /// for an item without a server stamp.
    func musicRoute(for item: JellyfinItem) -> (service: JellyfinMusicServiceProtocol, userID: String?) {
        let session = sessionRegistry.session(for: item)
        return session.isActive ? (jellyfinMusicService, activeUserID) : (session.musicService, session.userID)
    }

    // MARK: - Session-bound reports (audit LTM-201, LTM-R201)

    /// A playback service on a client of its own that carries the active session's address and
    /// token as they are right now. The live client reads both when a request is SENT, so a report
    /// that goes out after a profile or server switch would land in the new account. nil while the
    /// address has not proved itself: such a session gets no token on a snapshot either.
    func snapshotPlaybackService() -> JellyfinPlaybackServiceProtocol? {
        guard let base = jellyfinClient.verifiedBaseURL, let token = jellyfinClient.verifiedAccessToken else { return nil }
        let client = JellyfinClient(httpClient: httpClient)
        client.onAccessTokenSet = { LogSecrets.register($0) }
        client.baseURL = base
        client.accessToken = token
        return JellyfinPlaybackService(client: client)
    }

    /// The resolver for the session a long-lived piece of work starts under. Every call builds a
    /// snapshot of the session that is active at THAT moment (like video's stop), because the report
    /// goes out in a Task that runs after a synchronous profile switch already swapped the token on
    /// the live client. While the token is still the starting one that is the right session; after
    /// it changed, the snapshot taken at the start answers. An address that has not proved itself has
    /// no snapshot, and the report is skipped rather than sent through the live client (R-W2-1).
    func boundPlaybackReporter() -> () -> JellyfinPlaybackServiceProtocol? {
        let token = jellyfinClient.accessToken
        let startSnapshot = snapshotPlaybackService()
        return { [weak self] in
            guard let self else { return startSnapshot }
            return self.jellyfinClient.accessToken == token ? self.snapshotPlaybackService() : startSnapshot
        }
    }

    /// `service` itself for a secondary session (its own client never switches), a snapshot of the
    /// active session for the live one. For a report about to be sent from a task that outlives the
    /// screen, such as a player's stop.
    func sessionBoundReportService(for service: JellyfinPlaybackServiceProtocol) -> JellyfinPlaybackServiceProtocol {
        guard (service as AnyObject) === (jellyfinPlaybackService as AnyObject) else { return service }
        return snapshotPlaybackService() ?? service
    }
}
