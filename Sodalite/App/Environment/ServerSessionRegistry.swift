import Foundation
import Observation

/// Every Jellyfin session the app holds at once: the active one plus, in a combined Home, up to
/// four more (Sodalite#85). Mode off leaves `participants == [active]`.
@MainActor
@Observable
final class ServerSessionRegistry {
    let active: ServerSession
    private(set) var participants: [ServerSession]
    private(set) var participantsRevision: UInt64 = 0
    /// Bumped when a secondary moves to another address, which can turn an unreachable server into a
    /// reachable one without any participant changing.
    private(set) var routesRevision: UInt64 = 0

    @ObservationIgnored private let httpClient: HTTPClientProtocol
    @ObservationIgnored private var secondaries: [String: (session: ServerSession, credential: SessionCredential)] = [:]
    /// The credential each muted server refused. Keyed by credential, not just server, so signing
    /// in again brings the server back at once instead of at the next launch.
    @ObservationIgnored private var muted: [String: SessionCredential] = [:]
    @ObservationIgnored private var lastSignature: [String] = []

    init(
        activeClient: JellyfinClient,
        httpClient: HTTPClientProtocol,
        libraryService: JellyfinLibraryServiceProtocol? = nil,
        itemService: JellyfinItemServiceProtocol? = nil,
        playbackService: JellyfinPlaybackServiceProtocol? = nil,
        liveTvService: JellyfinLiveTvServiceProtocol? = nil
    ) {
        self.httpClient = httpClient
        let active = ServerSession(
            client: activeClient,
            libraryService: libraryService ?? JellyfinLibraryService(client: activeClient),
            itemService: itemService ?? JellyfinItemService(client: activeClient),
            playbackService: playbackService ?? JellyfinPlaybackService(client: activeClient),
            liveTvService: liveTvService ?? JellyfinLiveTvService(client: activeClient),
            isActive: true,
            server: nil,
            userID: ""
        )
        self.active = active
        self.participants = [active]
    }

    func apply(
        active activeIdentity: (server: JellyfinServer, userID: String)?,
        secondaries candidates: [ParticipantCandidate],
        baseURL: (JellyfinServer) -> URL
    ) {
        active.updateActive(server: activeIdentity?.server, userID: activeIdentity?.userID ?? "")
        let wanted = candidates.filter { muted[$0.server.id] != $0.credential }
        var next: [String: (session: ServerSession, credential: SessionCredential)] = [:]
        for candidate in wanted {
            // A changed address or name builds a fresh session, so its client and route follow.
            if let existing = secondaries[candidate.server.id], existing.credential == candidate.credential,
               existing.session.server == candidate.server {
                next[candidate.server.id] = existing
            } else {
                next[candidate.server.id] = (
                    ServerSession.secondary(candidate, baseURL: baseURL(candidate.server), httpClient: httpClient),
                    candidate.credential
                )
            }
        }
        secondaries = next
        participants = [active] + wanted.compactMap { next[$0.server.id]?.session }
        noteParticipantsChanged()
    }

    /// A secondary that refused its token sits out until it has a new one; a re-auth prompt for a
    /// server nobody is looking at would be worse than its rows going missing.
    func mute(serverID: String) {
        guard let credential = secondaries[serverID]?.credential, muted[serverID] != credential else { return }
        muted[serverID] = credential
        LogTap.shared.note("[sessions] secondary \(serverID.prefix(8)) refused its token, left out until it signs in again")
        secondaries[serverID] = nil
        participants.removeAll { !$0.isActive && $0.server?.id == serverID }
        noteParticipantsChanged()
    }

    func session(forServerID serverID: String?) -> ServerSession {
        guard let serverID, serverID != active.server?.id else { return active }
        return secondaries[serverID]?.session ?? active
    }

    func session(for item: JellyfinItem) -> ServerSession { session(forServerID: item.serverID) }

    func endpoint(forServerID serverID: String?) -> (baseURL: URL, token: String?)? {
        let client = session(forServerID: serverID).client
        guard let base = client.baseURL else { return nil }
        return (base, client.accessToken)
    }

    func updateRoute(_ url: URL, for session: ServerSession) {
        guard session.client.baseURL != url else { return }
        session.client.baseURL = url
        routesRevision &+= 1
    }

    private func noteParticipantsChanged() {
        let signature = participants.map { "\($0.server?.id ?? "")|\($0.userID)|\($0.client.accessToken ?? "")" }
        guard signature != lastSignature else { return }
        lastSignature = signature
        participantsRevision &+= 1
    }
}
