import Foundation
import Observation

/// One Jellyfin server's live session: a client and the services built on it (Sodalite#85). The
/// active session wraps the container's own `jellyfinClient`, whose writers stay where they are.
@MainActor
@Observable
final class ServerSession {
    let client: JellyfinClient
    let libraryService: JellyfinLibraryServiceProtocol
    let itemService: JellyfinItemServiceProtocol
    let playbackService: JellyfinPlaybackServiceProtocol
    let liveTvService: JellyfinLiveTvServiceProtocol
    let musicService: JellyfinMusicServiceProtocol
    let isActive: Bool
    private(set) var server: JellyfinServer?
    private(set) var userID: String
    /// A secondary's account as its server sees it, for the policy (Sodalite#202). nil until it has
    /// loaded, and always on the active session, whose user lives in `AppState`.
    private(set) var user: JellyfinUser?

    init(
        client: JellyfinClient,
        libraryService: JellyfinLibraryServiceProtocol,
        itemService: JellyfinItemServiceProtocol,
        playbackService: JellyfinPlaybackServiceProtocol,
        liveTvService: JellyfinLiveTvServiceProtocol,
        musicService: JellyfinMusicServiceProtocol,
        isActive: Bool,
        server: JellyfinServer?,
        userID: String
    ) {
        self.client = client
        self.libraryService = libraryService
        self.itemService = itemService
        self.playbackService = playbackService
        self.liveTvService = liveTvService
        self.musicService = musicService
        self.isActive = isActive
        self.server = server
        self.userID = userID
    }

    /// A secondary session on its own client over the shared Jellyfin HTTPClient, so the request
    /// limit stays one ceiling for every server.
    static func secondary(_ candidate: ParticipantCandidate, baseURL: URL, httpClient: HTTPClientProtocol) -> ServerSession {
        let client = JellyfinClient(httpClient: httpClient)
        client.onAccessTokenSet = { LogSecrets.register($0) }
        client.baseURL = baseURL
        client.accessToken = candidate.credential.token
        let libraryService = JellyfinLibraryService(client: client)
        return ServerSession(
            client: client,
            libraryService: libraryService,
            itemService: JellyfinItemService(client: client),
            playbackService: JellyfinPlaybackService(client: client),
            liveTvService: JellyfinLiveTvService(client: client),
            musicService: JellyfinMusicService(client: client, libraryService: libraryService),
            isActive: false,
            server: candidate.server,
            userID: candidate.credential.userID
        )
    }

    /// Loads `user` once; a server that is away gets asked again on the next refresh or route probe.
    func loadUserIfNeeded() async {
        guard !isActive, user == nil,
              let loaded = try? await JellyfinAuthService(client: client).getCurrentUser() else { return }
        user = loaded
    }

    func updateActive(server: JellyfinServer?, userID: String) {
        self.server = server
        self.userID = userID
    }
}
