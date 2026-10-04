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
    }

    /// Points each secondary at whichever of its addresses answers, as `resolveJellyfinRoute` does
    /// for the active one.
    func resolveSecondaryRoutes() async {
        for session in sessionRegistry.participants where !session.isActive {
            guard let server = session.server else { continue }
            guard let resolved = await ServerRouteResolver.resolve(
                internalURL: server.internalURL,
                externalURL: server.externalURL,
                lastKnown: serverRouteStore.lastRoute(serverID: server.id),
                probe: { [jellyfinProbe, id = server.id] in await jellyfinProbe($0, id) }
            ) else { continue }
            serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
            session.client.baseURL = resolved.url
        }
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
}
