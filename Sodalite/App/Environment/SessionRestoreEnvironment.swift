import Foundation

/// The exact, narrow surface `SessionRestorer.restore()` needs from the session store. Extracted as a seam so the restore policy (multi-profile routing + the parental-controls cold-start lock) can be unit-tested against a fake, without touching the real keychain or UserDefaults. `DependencyContainer` is the production conformance below; tests inject a fake.
@MainActor
protocol SessionRestoreEnvironment {
    /// True when a tvOS per-profile mapping is in effect for the current system user; suppresses defaultServer promotion + the useDefault branch so the system identity isn't clobbered.
    var defaultServerID: String? { get }
    var launchBehavior: AuthPreferences.LaunchBehavior { get }
    var activeServer: JellyfinServer? { get }

    /// Default profile pinned on one server; per server, so a pin on another server can never auto-enter here.
    func defaultUserID(serverID: String) -> String?
    func listKnownServers() -> [JellyfinServer]
    func listRememberedUsers(serverID: String) -> [RememberedUser]
    /// Route-aware best guess for a server's base URL: the persisted last-known route, else server.url. Satisfied by DependencyContainer's existing member.
    func preferredURL(for server: JellyfinServer) -> URL

    func loadActiveServerID() -> String?
    func loadUserID(serverID: String) -> String?
    func loadActiveUserName() -> String?
    func loadActiveUserImageTag() -> String?
    func loadAccessToken(serverID: String) -> String?

    func restoreSession() -> Bool
    func parentalControlsActive() -> Bool
    func isProtected(serverID: String, userID: String) -> Bool

    func saveActiveServerID(_ id: String)
    func saveActiveUserImageTag(_ tag: String)
    func setClientBaseURL(_ url: URL)
    func rememberUser(_ user: RememberedUser) throws
    func switchToUser(_ user: RememberedUser, server: JellyfinServer) throws
}

/// Production conformance: forwards to the container's existing session-store members. The members declared here are the thin ones the protocol needs but that don't already exist on the container (the rest, e.g. `listKnownServers`/`restoreSession`/`switchToUser`, satisfy the protocol directly).
@MainActor
extension DependencyContainer: SessionRestoreEnvironment {
    var defaultServerID: String? { authPreferences.defaultServerID }
    var launchBehavior: AuthPreferences.LaunchBehavior { authPreferences.launchBehavior }

    func defaultUserID(serverID: String) -> String? {
        authPreferences.defaultUserID(serverID: serverID)
    }

    func loadActiveServerID() -> String? {
        try? keychainService.loadString(for: KeychainKeys.activeServerID)
    }
    func loadUserID(serverID: String) -> String? {
        try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))
    }
    func loadActiveUserName() -> String? {
        try? keychainService.loadString(for: KeychainKeys.activeUserName)
    }
    func loadActiveUserImageTag() -> String? {
        try? keychainService.loadString(for: KeychainKeys.activeUserImageTag)
    }
    func loadAccessToken(serverID: String) -> String? {
        try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: serverID))
    }
    func isProtected(serverID: String, userID: String) -> Bool {
        parentalControlsPreferences.isProtected(serverID: serverID, userID: userID)
    }
    func saveActiveServerID(_ id: String) {
        try? keychainService.save(id, for: KeychainKeys.activeServerID)
    }
    func saveActiveUserImageTag(_ tag: String) {
        try? keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
    }
    func setClientBaseURL(_ url: URL) {
        jellyfinClient.baseURL = url
        liveRouteDidChange()
    }
}
