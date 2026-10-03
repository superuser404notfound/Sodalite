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

    @ObservationIgnored private let httpClient: HTTPClientProtocol
    @ObservationIgnored private var secondaries: [String: (session: ServerSession, credential: SessionCredential)] = [:]
    @ObservationIgnored private var muted: Set<String> = []
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
        let wanted = candidates.filter { !muted.contains($0.server.id) }
        var next: [String: (session: ServerSession, credential: SessionCredential)] = [:]
        for candidate in wanted {
            if let existing = secondaries[candidate.server.id], existing.credential == candidate.credential {
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

    /// A secondary that refused its token sits out until the next launch; a re-auth prompt for a
    /// server nobody is looking at would be worse than its rows going missing.
    func mute(serverID: String) {
        guard !muted.contains(serverID) else { return }
        muted.insert(serverID)
        LogTap.shared.note("[sessions] secondary \(serverID.prefix(8)) refused its token, left out until next launch")
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

    /// The token a request to `host:port` may carry, matched against every participant's base URL
    /// with scheme default ports applied.
    func token(forHost host: String?, port: Int?) -> String? {
        guard let host else { return nil }
        for session in participants {
            guard let base = session.client.baseURL, base.host == host else { continue }
            let basePort = base.port ?? Self.defaultPort(base.scheme)
            if basePort == (port ?? Self.defaultPort(base.scheme)) {
                return session.client.accessToken
            }
        }
        return nil
    }

    private static func defaultPort(_ scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    private func noteParticipantsChanged() {
        let signature = participants.map { "\($0.server?.id ?? "")|\($0.userID)|\($0.client.accessToken ?? "")" }
        guard signature != lastSignature else { return }
        lastSignature = signature
        participantsRevision &+= 1
    }
}
