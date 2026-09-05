import SwiftUI

/// Shown on cold launch when the user has multiple remembered
/// profiles for the active server. Picking a card re-uses the
/// cached token via `switchToUser`, no password re-entry.
///
/// Long-pressing a card opens a confirm-to-forget menu. The
/// "Add another profile" button jumps straight to LoginView for
/// the same server (server discovery is already done).
struct LaunchProfilePickerView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    let server: JellyfinServer
    /// Cold-launch root, mid-session reprompt cover (issue #41), or the cover a server switch raises
    /// when the target holds no session this device may resume unasked (Sodalite#74). In reprompt
    /// context, picking the active profile must not switch or clear caches, just dismiss; in
    /// switchServer context every card belongs to another server, so every card is a real switch.
    enum Context { case launch, reprompt, switchServer }
    var context: Context = .launch
    /// Cover dismissal (reprompt + switchServer); nil in launch context.
    var onFinished: (() -> Void)? = nil

    @State private var rememberedUsers: [RememberedUser] = []
    @State private var navigateToAddProfile = false
    @State private var switchError: String?
    /// Set when this picker is the screen a refused profile landed on; its own alert, because the
    /// switch-failed title would be describing something the user never did (Sodalite#90).
    @State private var rejectionNotice: String?
    @State private var showServerSwitchSheet = false
    @State private var showAddServerFlow = false

    /// Anchors the focus scope so cold-launch focus lands on a profile card, not the server-switch button (issue #25).
    @Namespace private var focusNamespace

    var body: some View {
        ThemeNavigationStack {
            VStack(spacing: 40) {
                header

                profileGrid

                serverSwitchButton

                addProfileButton
                    .focusSectionCompat()
            }
            .focusScopeCompat(focusNamespace)
            .screenContentInset()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(isPresented: $navigateToAddProfile) {
                UserPickerView(server: server)
                    .themedNavigationDestination()
            }
            .alert(
                String(localized: "profile.switch.failed.title",
                       defaultValue: "Couldn't switch profile"),
                isPresented: Binding(
                    get: { switchError != nil },
                    set: { if !$0 { switchError = nil } }
                ),
                presenting: switchError
            ) { _ in
                Button(String(localized: "common.ok", defaultValue: "OK")) {
                    switchError = nil
                }
            } message: { message in
                Text(message)
            }
            .alert(
                String(localized: "profile.rejected.title",
                       defaultValue: "Profile removed"),
                isPresented: Binding(
                    get: { rejectionNotice != nil },
                    set: { if !$0 { rejectionNotice = nil } }
                ),
                presenting: rejectionNotice
            ) { _ in
                Button(String(localized: "common.ok", defaultValue: "OK")) {
                    rejectionNotice = nil
                }
            } message: { message in
                Text(message)
            }
            .onAppear {
                reloadProfiles()
                showRejectionNoticeIfAny()
            }
            // Hold the cards against the server's own user table: a profile deleted there used to
            // keep its card in here forever, and picking it entered a session the server answers
            // nothing for (Sodalite#90).
            .task {
                guard dependencies.activeServer?.id == server.id else { return }
                let reconcile = await dependencies.reconcileRememberedProfiles()
                guard reconcile.dropped > 0 else { return }
                reloadProfiles()
                // The pass can find that the session this screen is sitting on top of is the one
                // the server dropped, which is what this picker is here to catch (Sodalite#90).
                if reconcile.endedActiveSession, appState.isAuthenticated {
                    // This cover is going away with the session, so the notice stays on AppState
                    // and is spent on the picker AppRouter raises in its place.
                    dependencies.requestSessionReroute()
                    onFinished?()
                } else {
                    showRejectionNoticeIfAny()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidApplyChanges)) { _ in
                reloadProfiles()
            }
            // Add-profile / add-server from inside the reprompt cover authenticates underneath
            // (setAuthenticated without a serverDidSwitch bump); drop the cover instead of
            // stranding the user on the picker until they tap the now-active card.
            .onReceive(NotificationCenter.default.publisher(for: .loginDidComplete)) { _ in
                if context != .launch { onFinished?() }
            }
            .sheet(isPresented: $showServerSwitchSheet) {
                ServerSwitchSheet(
                    onAddServer: {
                        showAddServerFlow = true
                    },
                    onSwitched: { switched in
                        // Only a switch that happened drops the cover: serverDidSwitch authenticates
                        // underneath it. One that deferred to another server's picker (Sodalite#74) must
                        // leave it standing, else this cover dismisses into the one AppRouter is about to
                        // raise. Launch context re-resolves through AppRouter's launchPickerServer.
                        if switched { onFinished?() }
                    }
                )
            }
            .fullScreenCover(isPresented: $showAddServerFlow) {
                ServerDiscoveryView(addMode: true) {
                    showAddServerFlow = false
                }
                .themedPresentationBackground()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Text(server.name)
                .font(.title2)
                .fontWeight(.semibold)

            Text(String(
                localized: "profile.launch.subtitle",
                defaultValue: "Who's watching?"
            ))
            .font(.body)
            .foregroundStyle(.secondary)

            // The removal menu is a long press with nothing on screen pointing at it, which on tvOS
            // is a gesture nobody finds by accident (Sodalite#90).
            if !rememberedUsers.isEmpty {
                Text(String(
                    localized: "profile.launch.removeHint",
                    defaultValue: "Long-press a profile to remove it."
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Server switch

    private var serverSwitchButton: some View {
        Button(action: { gateThenServerSwitch() }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("multiServer.picker.header.label", bundle: .main)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(server.name)
                        .font(.headline)
                    Text(server.url.host() ?? server.url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        .frame(maxWidth: 560)
    }

    // MARK: - Grid

    private var profileGrid: some View {
        #if os(tvOS)
        let maxCols = 5
        #else
        let maxCols = hSizeClass == .compact ? 2 : 4
        #endif
        let columnCount = max(1, min(rememberedUsers.count, maxCols))
        let m = LayoutMetrics.current(hSizeClass)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(m.profileCardSize.width), spacing: 28),
                    count: columnCount
                ),
                spacing: 32
            ) {
                ForEach(rememberedUsers) { user in
                    let isCurrent = user.id == activeSessionUserID
                    RememberedProfileCard(
                        user: user,
                        server: server,
                        isCurrent: isCurrent,
                        // The signed-in profile takes the session with it, so its menu says so
                        // (Sodalite#90). A plain forget would leave the active token behind and
                        // SessionRestorer's migration block would resurrect the entry next launch.
                        removal: removal(for: user, isCurrent: isCurrent),
                        onSelect: { select(user) },
                        onLongPress: {
                            if isCurrent {
                                signOutOfCurrentProfile()
                            } else {
                                forget(user)
                            }
                        }
                    )
                    // Pre-focus default profile, else the active-session profile, else the first card (issues #25, #41).
                    .prefersDefaultFocusCompat(isPreferredDefault(user), in: focusNamespace)
                }
            }
            Spacer(minLength: 0)
        }
        .focusSectionCompat()
    }

    private func isPreferredDefault(_ user: RememberedUser) -> Bool {
        user.id == ProfilePickerOrdering.preferredFocusID(
            users: rememberedUsers,
            defaultID: dependencies.authPreferences.defaultUserID(serverID: server.id),
            activeID: activeSessionUserID
        )
    }

    // MARK: - Add Profile

    private var addProfileButton: some View {
        Button {
            gateThenAddProfile()
        } label: {
            Label {
                Text(String(
                    localized: "profile.addAnother",
                    defaultValue: "Add another profile"
                ))
            } icon: {
                Image(systemName: "plus.circle")
            }
            .font(.body)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        // Same SettingsTileButtonStyle tint trap as ProfileSettingsView addProfileButton: default tvOS bordered style fills with tint and bleeds it into the Label; tile style keeps the label in primary foreground.
        .buttonStyle(SettingsTileButtonStyle())
    }

    // MARK: - Actions

    private func select(_ user: RememberedUser) {
        // Reprompt context, active profile tapped: continue as current, same as a Menu dismiss.
        // Nothing is activated, so an open or locked-in profile continues free, as before. An
        // entry-locked one does not: the reprompt asks because the person at the TV may have
        // changed, and waving the last active card through is the one way in that lock is for.
        // Legitimate exits stay open, their own card is a normal free select, and the pad offers
        // recovery.
        if context == .reprompt, user.id == activeSessionUserID {
            guard dependencies.parentalGateRequired(forActivatingUserID: user.id,
                                                    serverID: server.id) else {
                onFinished?()
                return
            }
            let reason = dependencies.parentalGateReason(forActivatingUserID: user.id,
                                                         serverID: server.id)
            Task {
                if await dependencies.parentalGate.challenge(reason: reason) { onFinished?() }
            }
            return
        }
        // An entry-locked profile always costs the PIN, a locked-in one enters free, and an open
        // one costs it only as the far side of the leave-lock.
        if dependencies.parentalGateRequired(forActivatingUserID: user.id,
                                              serverID: server.id) {
            let reason = dependencies.parentalGateReason(forActivatingUserID: user.id,
                                                         serverID: server.id)
            Task {
                let unlocked = await dependencies.parentalGate.challenge(reason: reason)
                if unlocked { performSelect(user) }
            }
        } else {
            performSelect(user)
        }
    }

    private func performSelect(_ user: RememberedUser) {
        do {
            // switchToUser purges the identity-scoped caches (images, filter pages) itself.
            try dependencies.switchToUser(user, server: server)
            let jf = JellyfinUser(
                id: user.id,
                name: user.name,
                serverID: server.id,
                hasPassword: nil,
                primaryImageTag: user.imageTag,
                policy: nil
            )
            // Read the server back rather than reusing the captured copy: an iCloud record applied
            // since this view was built may have changed its URL slots (Sodalite#45).
            appState.setAuthenticated(server: dependencies.activeServer ?? server, user: jf)

            // Restore this profile's own remembered Seerr session (else Catalog shows the "set up Seerr" empty state).
            Task { await restoreSeerrForProfile(userID: user.id, serverID: server.id) }
            // Backfill missing PrimaryImageTag + the server-side Policy block (drives the File Management gate) from /Users/Me, else the delete button stays hidden after switching back.
            Task { await refreshUserDetails(userID: user.id, serverID: server.id) }
            onFinished?()
        } catch {
            switchError = ErrorText.user(for: error)
        }
    }

    private func gateThenServerSwitch() {
        guard dependencies.parentalControlsActive() else { showServerSwitchSheet = true; return }
        Task {
            if await dependencies.parentalGate.challenge(reason: .serverManagement) {
                showServerSwitchSheet = true
            }
        }
    }

    private func gateThenAddProfile() {
        guard dependencies.parentalControlsActive() else { navigateToAddProfile = true; return }
        Task {
            if await dependencies.parentalGate.challenge(reason: .serverManagement) {
                navigateToAddProfile = true
            }
        }
    }

    private func refreshUserDetails(userID: String, serverID: String) async {
        // Fetch + persistence live in the container; this view only applies the refreshed user to AppState.
        switch await dependencies.refreshActiveUserDetails(
            expectedUserID: userID,
            serverID: serverID
        ) {
        case .kept(let fresh):
            if let fresh { appState.activeUser = fresh }
        case .rejected:
            // The picked profile's token is dead and no password could replace it, so the container
            // dropped it. Hand routing back to AppRouter, which lands on this server's picker again,
            // where the notice is shown (Sodalite#90).
            dependencies.requestSessionReroute()
            onFinished?()
        }
    }

    private func restoreSeerrForProfile(userID: String, serverID: String) async {
        // allowLegacyFallback mirrors AppRouter launch-restore: a pre-0.3.0 install on the picker has only the legacy global Seerr entry, else it never bridges to a scoped copy here.
        let outcome = await dependencies.syncSeerrSession(
            forJellyfinUserID: userID,
            jellyfinServerID: serverID,
            allowLegacyFallback: true
        )
        if case .connected(let server, let user) = outcome {
            appState.setSeerrConnected(server: server, user: user)
            dependencies.scheduleRouteResolve()
        } else {
            appState.disconnectSeerr()
        }
    }

    /// The profile the active session points at. `AppState.activeUser` may not be populated at the
    /// picker, so read the keychain for this server directly.
    private var activeSessionUserID: String? {
        try? dependencies.keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
    }

    private func reloadProfiles() {
        rememberedUsers = ProfilePickerOrdering.orderedForPicker(
            dependencies.listRememberedUsers(serverID: server.id),
            activeID: activeSessionUserID
        )
    }

    /// A profile the server refused is dropped wherever the refusal was noticed, which is rarely
    /// this screen. The notice travels on AppState and is spent here, on the picker the session
    /// lands on (Sodalite#90).
    private func showRejectionNoticeIfAny() {
        guard let name = appState.rejectedProfileName else { return }
        appState.rejectedProfileName = nil
        rejectionNotice = String(
            format: String(
                localized: "profile.rejected.detail %@",
                defaultValue: "The server refused the saved sign-in for %@, so the profile was removed from this device. Sign in again if the account still exists."
            ),
            name
        )
    }

    /// What long-pressing a card offers. The signed-in profile can go too, it just takes the session
    /// with it; a card that is another server's current pointer cannot (this device would keep that
    /// server's token with nothing remembering it, and the next launch there would resurrect the
    /// entry through SessionRestorer's migration).
    private func removal(for user: RememberedUser, isCurrent: Bool) -> RememberedProfileCard.Removal {
        guard isCurrent else { return .forget }
        return dependencies.activeServer?.id == server.id ? .signOut : .unavailable
    }

    private func signOutOfCurrentProfile() {
        guard dependencies.activeServer?.id == server.id else { return }
        dependencies.signOutOfActiveProfile()
        reloadProfiles()
        onFinished?()
    }

    private func forget(_ user: RememberedUser) {
        // The signed-in profile goes through signOutOfActiveProfile instead: a plain forget would
        // leave the active token in the keychain and SessionRestorer's migration block would
        // resurrect the entry on the next launch.
        guard user.id != activeSessionUserID else { return }
        // Not an escape route, the card cannot be re-entered without its password either way, but
        // without this a child at the picker can delete the cards they are being kept out of.
        guard dependencies.parentalControlsActive() else { performForget(user); return }
        Task {
            if await dependencies.parentalGate.challenge(reason: .serverManagement) {
                performForget(user)
            }
        }
    }

    private func performForget(_ user: RememberedUser) {
        do {
            try dependencies.forgetUser(id: user.id, serverID: server.id)
            reloadProfiles()
        } catch {
            switchError = ErrorText.user(for: error)
        }
    }
}

// MARK: - Card

/// Circular avatar + name card with long-press-to-forget. Matches UserPickerCard for consistency between the two pickers.
struct RememberedProfileCard: View {
    /// What the long-press menu offers for this card. The signed-in profile can be removed too, it
    /// just ends the session with it; `unavailable` draws no menu at all, which is what a card whose
    /// removal would leave a half-torn-down session behind gets (Sodalite#90). Before that it drew a
    /// "Remove profile" item whose action the callers dropped on the floor.
    enum Removal { case forget, signOut, unavailable }

    let user: RememberedUser
    let server: JellyfinServer
    /// Marks the active session: green checkmark badge + idle ring so the current login is spottable in an otherwise-identical grid.
    var isCurrent: Bool = false
    var removal: Removal = .forget
    let onSelect: () -> Void
    let onLongPress: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var isFocused: Bool

    private var diameter: CGFloat { hSizeClass == .compact ? 110 : 160 }

    var body: some View {
        // The menu is attached or it is not; no branch inside it, so a card never swaps identity
        // (and its focus with it) while the picker is on screen.
        if removal == .unavailable {
            card
        } else {
            card
                // Long-press opens a context menu; tapping the item is the explicit confirm against accidental deletion.
                .contextMenu {
                    Button(role: .destructive, action: onLongPress) {
                        if removal == .signOut {
                            Label(
                                String(localized: "profile.signOut.confirm.short",
                                       defaultValue: "Sign out and remove"),
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                        } else {
                            Label(
                                String(localized: "profile.forget.confirm.short",
                                       defaultValue: "Remove profile"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
        }
    }

    private var card: some View {
        Button(action: onSelect) {
            VStack(spacing: 16) {
                avatar
                Text(user.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
        }
        // BareButtonStyle suppresses tvOS' default thick white focus halo; the avatar overlay draws our tint (or green-when-current) ring instead.
        .buttonStyle(BareButtonStyle())
        .focused($isFocused)
    }

    private var avatar: some View {
        ZStack {
            if let url = profileImageURL {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsCircle
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            } else {
                initialsCircle
                    .frame(width: diameter, height: diameter)
            }
        }
        .overlay(
            // Green idle ring on the active profile; suppressed when focused (focus-tint ring takes over).
            Circle()
                .strokeBorder(.green, lineWidth: 4)
                .padding(-3)
                .opacity(isCurrent && !isFocused ? 0.85 : 0)
        )
        .overlay(
            Circle()
                .strokeBorder(.tint, lineWidth: 3)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
        )
        .overlay(alignment: .bottomTrailing) {
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.black.opacity(0.6)).blur(radius: 4))
                    .offset(x: 4, y: 4)
            }
        }
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    private var initialsCircle: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Text(initials)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private var initials: String {
        let parts = user.name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(user.name.prefix(2)).uppercased()
    }

    private var profileImageURL: URL? {
        // Against the card's own server: switchServer returns before it writes jellyfinClient.baseURL
        // when the target has no token slot on this device, which is exactly when this picker opens,
        // so the active client can still be pointing at the previous server (Sodalite#119).
        dependencies.jellyfinImageService.userProfileImageURL(
            userID: user.id,
            tag: user.imageTag,
            baseURL: dependencies.preferredURL(for: server),
            token: user.token
        )
    }
}
