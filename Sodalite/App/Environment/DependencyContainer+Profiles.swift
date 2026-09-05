import Foundation

/// Sodalite#90: the remembered profiles of a server are a local cache of a fact the server owns, and
/// nothing here used to re-read that fact. A user deleted on the server kept a card in every picker,
/// picking it entered a session no request would be answered for, and the only automatic cleanup
/// (the 401 in `probeActiveUser`) ran on a server switch and only for the profile that was already
/// active.
///
/// This is the other direction: ask the server who it has, and ask it whether the token this session
/// is holding still resolves. Everything that ends a profile goes through `dropActiveProfile` so a
/// removal always leaves the same state behind, tombstone included.
extension DependencyContainer {

    // MARK: - Is this session still real

    /// What the server said about the token the active session is holding.
    enum SessionCheck {
        /// The token resolves; the user carries the server's own name, policy and avatar tag.
        case valid(JellyfinUser)
        /// Nothing to check: no active server, no user pointer, or no token on this device.
        case noSession
        /// The token was refused and no stored password could mint a new one. The profile, its
        /// credentials and the session pointers are gone from this device; the caller does the routing.
        case rejected(profileName: String?)
        /// No answer (offline, server down, request cancelled). Nothing was changed.
        case unreachable(any Error)
    }

    /// What a post-switch refresh of the active profile found.
    enum ProfileRefresh {
        /// The session stands. Carries the refreshed user when something changed and the caller
        /// should apply it, nil when nothing did (or nobody was there to apply it to).
        case kept(JellyfinUser?)
        /// The server refused the token and no password could replace it: the profile is gone from
        /// this device and the caller routes back to the picker.
        case rejected(profileName: String?)
    }

    /// Asks `/Users/Me` whether the active session's token still resolves, and acts on a refusal:
    /// a stored password mints a fresh token (that key is scoped to this profile, so a password
    /// there is by definition theirs), and only when that fails too is the profile dropped.
    ///
    /// A refusal is only ever read off a 401. Anything else, a re-login that fails on the transport
    /// included, leaves every credential where it is: a device that cannot reach its server has not
    /// learned anything about which profiles the server still has.
    func checkActiveSession() async -> SessionCheck {
        guard let server = activeServer,
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)),
              (try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))) != nil
        else { return .noSession }

        do {
            return .valid(try await jellyfinAuthService.getCurrentUser())
        } catch APIError.unauthorized {
            if let recovered = await reauthenticateWithStoredPassword(server: server, userID: userID) {
                sessionNote("token for \(recovered.name) on \(server.name) was refused, the stored password minted a fresh one.")
                return .valid(recovered)
            }
            let name = listRememberedUsers(serverID: server.id).first { $0.id == userID }?.name
            sessionNote("\(server.name) refused the saved sign-in for \(name ?? userID), dropping the profile.")
            dropActiveProfile(serverID: server.id, userID: userID)
            // Set here, at the one place a profile is dropped for being refused, so every path that
            // ends on the picker can say why the card is gone without carrying the reason itself.
            appState?.rejectedProfileName = name
            return .rejected(profileName: name)
        } catch {
            return .unreachable(error)
        }
    }

    /// Mints a new token from the password stored for this exact profile. nil when there is none,
    /// when the server refuses it, or when it authenticates as somebody else.
    private func reauthenticateWithStoredPassword(
        server: JellyfinServer,
        userID: String
    ) async -> JellyfinUser? {
        guard let password = try? keychainService.loadString(
                  for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: userID)
              ),
              let name = listRememberedUsers(serverID: server.id).first(where: { $0.id == userID })?.name,
              let auth = try? await jellyfinAuthService.login(username: name, password: password),
              auth.user.id == userID
        else { return nil }
        try? saveSession(server: server, user: auth.user, token: auth.accessToken, password: password)
        return auth.user
    }

    // MARK: - Ending a profile

    /// Everything one profile leaves behind on this device, plus the session that was signed in as
    /// it: the remembered entry (as a tombstone, so the removal travels instead of a shorter list),
    /// its credentials, the session pointers, the mirrored session TopShelf reads, and the caches
    /// that were filled under its token. Deliberately does no routing, so the paths that are already
    /// inside AppRouter's switch probe do not re-key it out from under themselves.
    func dropActiveProfile(serverID: String, userID: String) {
        try? forgetUser(id: userID, serverID: serverID)

        try? keychainService.delete(for: KeychainKeys.accessToken(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.userID(serverID: serverID))
        // Global keys describing the session that just ended.
        try? keychainService.delete(for: KeychainKeys.activeUserName)
        try? keychainService.delete(for: KeychainKeys.activeUserImageTag)

        jellyfinClient.accessToken = nil
        SharedSessionMirror.clear()

        // This profile's rows and thumbnails carry its library permissions and watched flags, and
        // the profile is gone. Only its own entries: the other profiles on this server keep theirs.
        FilterCache.shared.evict(identity: CacheIdentity(serverID: serverID, userID: userID))
        ImageCache.shared.clear()

        // Background music is scoped to the session, and this one is over.
        if musicPlaybackCoordinator.currentItem != nil {
            musicPlaybackCoordinator.stop()
        }
    }

    /// Removes the profile the session is signed in as and re-routes.
    func signOutOfActiveProfile() {
        guard let server = activeServer,
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        else { return }
        let name = listRememberedUsers(serverID: server.id).first { $0.id == userID }?.name
        sessionNote("removing the signed-in profile \(name ?? userID) from \(server.name).")
        dropActiveProfile(serverID: server.id, userID: userID)
        requestSessionReroute()
    }

    /// Asks AppRouter to re-resolve where the session belongs, on the same signal a server switch
    /// raises: its probe reads whatever is (or is no longer) on this device and sets the picker and
    /// the authenticated flag in one update, which is what keeps the discovery screen from flashing
    /// between the two.
    ///
    /// Never call this from inside that probe (`probeActiveUser`): the bump re-keys the task it runs
    /// in and cancels it mid-flight. The probe's own nil return is the routing there.
    func requestSessionReroute() {
        appState?.serverDidSwitch &+= 1
    }

    // MARK: - Reconcile against the server's user table

    /// What one reconcile pass changed on this device.
    struct ReconcileOutcome {
        /// Remembered profiles dropped, the signed-in one included.
        let dropped: Int
        /// The session ended with one of them: the caller routes back to the server's picker.
        let endedActiveSession: Bool

        static let none = ReconcileOutcome(dropped: 0, endedActiveSession: false)
    }

    /// Holds the active server's remembered profiles against the server's own user table and drops
    /// the ones it no longer has. Answers "who is on this server" with `/Users`, which needs a token
    /// but no admin rights and hides nobody. `/Users/Public` is a login-screen list (no hidden, no
    /// disabled, filtered by device access and, from outside the local network, by remote-access
    /// permission), so a profile missing from it is not evidence of anything.
    ///
    /// Only the active server: the reconcile rides the session's own token, and the other servers
    /// get their pass when they become active.
    @discardableResult
    func reconcileRememberedProfiles(minimumInterval: TimeInterval = 30) async -> ReconcileOutcome {
        guard let server = activeServer,
              (try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))) != nil
        else { return .none }

        // The launch pass and the picker that comes up right behind it must not each ask.
        if let last = lastProfileReconcile[server.id],
           Date.now.timeIntervalSince(last) < minimumInterval {
            return .none
        }

        guard !listRememberedUsers(serverID: server.id).isEmpty else { return .none }

        let serverUserIDs: [String]
        do {
            serverUserIDs = try await jellyfinAuthService.getAllUsers().map(\.id)
            lastProfileReconcile[server.id] = .now
        } catch APIError.unauthorized {
            // Deleting a user takes its tokens with it, so the table can come back refused instead
            // of arriving without the user in it. That refusal is still an answer, and the profile
            // it is about is the one whose token was refused. The rest of the list keeps its cards
            // until a session that the server does answer can speak for them.
            return await endSessionIfRefused()
        } catch {
            return .none
        }

        // A table that does not list the session's own user is either a table this session does not
        // live in (a proxy, another backend behind the same URL) or the table of a server that just
        // deleted this profile. Nothing in the table itself tells the two apart, so ask the token:
        // one still resolves, the other is refused (Sodalite#90).
        let activeUserID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        var ended = ReconcileOutcome.none
        if RememberedProfileReconciliation.sessionUserIsAbsent(from: serverUserIDs, activeUserID: activeUserID) {
            ended = await endSessionIfRefused()
            guard ended.endedActiveSession else { return .none }
        }

        // Read the list back: the profile the session was signed in as may just have gone with it,
        // and with no session left, nothing has to be held against the table any more.
        let remembered = listRememberedUsers(serverID: server.id)
        let stale = RememberedProfileReconciliation.staleProfileIDs(
            remembered: remembered,
            serverUserIDs: serverUserIDs,
            activeUserID: ended.endedActiveSession ? nil : activeUserID
        )

        for id in stale {
            let name = remembered.first { $0.id == id }?.name ?? id
            sessionNote("\(name) is not a user on \(server.name) any more, dropping the remembered profile.")
            try? forgetUser(id: id, serverID: server.id)
        }
        return ReconcileOutcome(
            dropped: ended.dropped + stale.count,
            endedActiveSession: ended.endedActiveSession
        )
    }

    /// Asks the session check whether the token this session holds still resolves, and reports the
    /// profile it took with it when it did not. Everything a refusal entails (the stored-password
    /// retry first, then the tombstone, the credentials, the session pointers and the notice the
    /// picker shows) stays in `checkActiveSession`, the one place a refusal is acted on.
    private func endSessionIfRefused() async -> ReconcileOutcome {
        switch await checkActiveSession() {
        case .rejected:
            return ReconcileOutcome(dropped: 1, endedActiveSession: true)
        case .valid, .noSession, .unreachable:
            return .none
        }
    }
}
