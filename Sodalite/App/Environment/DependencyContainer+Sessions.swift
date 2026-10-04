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
