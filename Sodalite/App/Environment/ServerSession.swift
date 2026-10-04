import Foundation

/// One Jellyfin server's live session: a client and the services built on it (Sodalite#85). The
/// active session wraps the container's own `jellyfinClient`, whose writers stay where they are.
@MainActor
final class ServerSession {
    let client: JellyfinClient
    let libraryService: JellyfinLibraryServiceProtocol
    let itemService: JellyfinItemServiceProtocol
    let playbackService: JellyfinPlaybackServiceProtocol
    let liveTvService: JellyfinLiveTvServiceProtocol
    let isActive: Bool
    private(set) var server: JellyfinServer?
    private(set) var userID: String

    init(
        client: JellyfinClient,
        libraryService: JellyfinLibraryServiceProtocol,
        itemService: JellyfinItemServiceProtocol,
        playbackService: JellyfinPlaybackServiceProtocol,
        liveTvService: JellyfinLiveTvServiceProtocol,
        isActive: Bool,
        server: JellyfinServer?,
        userID: String
    ) {
        self.client = client
        self.libraryService = libraryService
        self.itemService = itemService
        self.playbackService = playbackService
        self.liveTvService = liveTvService
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
        return ServerSession(
            client: client,
            libraryService: JellyfinLibraryService(client: client),
            itemService: JellyfinItemService(client: client),
            playbackService: JellyfinPlaybackService(client: client),
            liveTvService: JellyfinLiveTvService(client: client),
            isActive: false,
            server: candidate.server,
            userID: candidate.credential.userID
        )
    }

    func updateActive(server: JellyfinServer?, userID: String) {
        self.server = server
        self.userID = userID
    }
}
