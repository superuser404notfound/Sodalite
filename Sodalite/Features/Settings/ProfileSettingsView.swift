import SwiftUI

/// Profile-switching for the active Jellyfin server: signed-in user, remembered profiles, launch-picker behavior, default profile.
struct ProfileSettingsView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var rememberedUsers: [RememberedUser] = []
    @State private var navigateToAddProfile = false
    @State private var actionError: String?
    /// tvOS doesn't auto-restore focus after nav pop; without this push, Menu escapes the nav stack and quits the app.
    @FocusState private var addProfileButtonFocused: Bool

    private var authPreferences: AuthPreferences {
        dependencies.authPreferences
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Text(String(localized: "settings.profile.title",
                            defaultValue: "Profile"))
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)

                profilesGrid

                addProfileButton

                launchBehaviorSection
            }
            .screenContentInset()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .hidesNavigationBarChrome()
        .navigationDestination(isPresented: $navigateToAddProfile) {
            if let server = appState.activeServer {
                // UserPickerView shows public profiles with avatars, or falls back to manual sign-in if the list is disabled.
                UserPickerView(server: server)
                    .themedNavigationDestination()
            }
        }
        .alert(
            String(localized: "profile.switch.failed.title",
                   defaultValue: "Couldn't switch profile"),
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button(String(localized: "common.ok", defaultValue: "OK")) {
                actionError = nil
            }
        } message: { message in
            Text(message)
        }
        .onAppear(perform: refresh)
        // Hold the cards against the server's own user table, so a profile deleted on the server
        // stops being offered here (Sodalite#90).
        .task {
            let reconcile = await dependencies.reconcileRememberedProfiles()
            guard reconcile.dropped > 0 else { return }
            refresh()
            // The profile the pass dropped can be the one this screen is signed in as; the session
            // ended with it, so hand routing back to AppRouter's picker (Sodalite#90).
            if reconcile.endedActiveSession {
                dependencies.requestSessionReroute()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loginDidComplete)) { _ in
            // LoginView flipped activeUser; pop the add-profile stack back so the active card updates.
            navigateToAddProfile = false
            refresh()
            // tvOS doesn't auto-restore focus after nav pop; without this push, Menu escapes the nav stack and quits the app.
            deferOnMain(by: 0.3) {
                addProfileButtonFocused = true
            }
        }
    }

    // MARK: - Profiles grid

    /// All remembered profiles side-by-side with a check-badge on the active one.
    @ViewBuilder
    private var profilesGrid: some View {
        if !rememberedUsers.isEmpty, let server = appState.activeServer {
            VStack(spacing: 16) {
                Text(String(
                    localized: "settings.profile.switchTo.hint",
                    defaultValue: "Tap to switch without signing in again. Long-press to remove."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

                let maxCols = hSizeClass == .compact ? 2 : 4
                let columnCount = max(1, min(rememberedUsers.count, maxCols))
                let m = LayoutMetrics.current(hSizeClass)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(m.profileCardSize.width), spacing: 28),
                            count: columnCount
                        ),
                        spacing: 32
                    ) {
                        ForEach(rememberedUsers) { user in
                            let isCurrent = user.id == appState.activeUser?.id
                            RememberedProfileCard(
                                user: user,
                                server: server,
                                isCurrent: isCurrent,
                                // The signed-in profile is removable here too, it just ends the
                                // session with it. Before Sodalite#90 the only way out of a profile
                                // you were signed in as was a full logout, which takes every server.
                                removal: isCurrent ? .signOut : .forget,
                                onSelect: {
                                    guard !isCurrent else { return }

                                    switchTo(user, server: server)
                                },
                                onLongPress: {
                                    if isCurrent {
                                        dependencies.signOutOfActiveProfile()
                                    } else {
                                        forget(user)
                                    }
                                }
                            )
                        }
                    }
                    Spacer(minLength: 0)
                }
                .focusSectionCompat()
            }
        }
    }

    // MARK: - Add another

    @ViewBuilder
    private var addProfileButton: some View {
        if appState.activeServer != nil {
            Button {
                navigateToAddProfile = true
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
            // Default tvOS bordered style tints the label invisible; SettingsTileButtonStyle uses white-opacity fill.
            .buttonStyle(SettingsTileButtonStyle())
            .focused($addProfileButtonFocused)
        }
    }

    // MARK: - Launch behavior

    private var launchBehaviorSection: some View {
        VStack(spacing: 20) {
            Text(String(
                localized: "settings.profile.launch.title",
                defaultValue: "On app launch"
            ))
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                ForEach(AuthPreferences.LaunchBehavior.allCases, id: \.self) { choice in
                    Button {
                        authPreferences.launchBehavior = choice
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: authPreferences.launchBehavior == choice
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(choice.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(20)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                    .accessibilityAddTraits(authPreferences.launchBehavior == choice ? .isSelected : [])
                }
            }

            if authPreferences.launchBehavior == .useDefault {
                defaultProfilePicker
            }

            if authPreferences.launchBehavior == .showPicker {
                repromptPicker
            }
        }
        .padding(.top, 12)
    }

    /// Pinned default profile of the active server (the pin is per server).
    private var defaultUserID: String? {
        guard let serverID = appState.activeServer?.id else { return nil }
        return authPreferences.defaultUserID(serverID: serverID)
    }

    @ViewBuilder
    private var defaultProfilePicker: some View {
        VStack(spacing: 12) {
            Text(String(
                localized: "settings.profile.default.title",
                defaultValue: "Default profile"
            ))
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)

            VStack(spacing: 8) {
                ForEach(rememberedUsers) { user in
                    Button {
                        if let serverID = appState.activeServer?.id {
                            authPreferences.setDefaultUserID(user.id, serverID: serverID)
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: defaultUserID == user.id
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(.tint)
                            Text(user.name)
                                .font(.body)
                            Spacer()
                        }
                        .padding(16)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                    .accessibilityAddTraits(defaultUserID == user.id ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var repromptPicker: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "settings.profile.reprompt.title",
                    defaultValue: "Show the picker again"
                ))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(String(
                    localized: "settings.profile.reprompt.detail",
                    defaultValue: "Ask who's watching when the app comes back after time in the background."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)

            VStack(spacing: 8) {
                ForEach(AuthPreferences.ProfileRepromptInterval.allCases, id: \.self) { choice in
                    Button {
                        authPreferences.profileReprompt = choice
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: authPreferences.profileReprompt == choice
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(.tint)
                            Text(choice.label)
                                .font(.body)
                            Spacer()
                        }
                        .padding(16)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                    .accessibilityAddTraits(authPreferences.profileReprompt == choice ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard let server = appState.activeServer else {
            rememberedUsers = []
            return
        }
        rememberedUsers = dependencies.listRememberedUsers(serverID: server.id)
    }

    private func switchTo(_ user: RememberedUser, server: JellyfinServer) {
        // An entry-locked target costs the PIN here too, which is the whole point of the role.
        guard dependencies.parentalGateRequired(forActivatingUserID: user.id,
                                                serverID: server.id) else {
            performSwitch(user, server: server)
            return
        }
        let reason = dependencies.parentalGateReason(forActivatingUserID: user.id,
                                                     serverID: server.id)
        Task {
            if await dependencies.parentalGate.challenge(reason: reason) {
                performSwitch(user, server: server)
            }
        }
    }

    private func performSwitch(_ user: RememberedUser, server: JellyfinServer) {
        do {
            // switchToUser drops the image cache itself; filter pages need no wipe, they carry the identity that fetched them.
            try dependencies.switchToUser(user, server: server)
            let jf = JellyfinUser(
                id: user.id,
                name: user.name,
                serverID: server.id,
                hasPassword: nil,
                primaryImageTag: user.imageTag,
                policy: nil
            )
            // Read the server back rather than reusing AppState's copy: an iCloud record applied
            // since this screen opened may have changed its URL slots (Sodalite#45).
            appState.setAuthenticated(server: dependencies.activeServer ?? server, user: jf)
            refresh()

            // Restore this profile's Seerr session (each Jellyfin user has a separate per-profile cookie in the keychain).
            Task { await restoreSeerrForSwitchedProfile(userID: user.id, serverID: server.id) }
            // Backfill a nil/stale PrimaryImageTag on older RememberedUser entries.
            Task { await refreshUserDetails(userID: user.id, serverID: server.id) }
        } catch {
            actionError = ErrorText.user(for: error)
        }
    }

    private func refreshUserDetails(userID: String, serverID: String) async {
        // Fetch + keychain persistence live in the container; this view only applies the result to AppState.
        switch await dependencies.refreshActiveUserDetails(
            expectedUserID: userID,
            serverID: serverID
        ) {
        case .kept(let fresh):
            if let fresh { appState.activeUser = fresh }
        case .rejected:
            // The switched-to profile's token is dead and the container dropped it; AppRouter's
            // probe lands on this server's picker, which carries the notice (Sodalite#90).
            dependencies.requestSessionReroute()
        }
    }

    private func restoreSeerrForSwitchedProfile(userID: String, serverID: String) async {
        let outcome = await dependencies.syncSeerrSession(
            forJellyfinUserID: userID,
            jellyfinServerID: serverID
        )
        if case .connected(let server, let user) = outcome {
            appState.setSeerrConnected(server: server, user: user)
            dependencies.scheduleRouteResolve()
        } else {
            appState.disconnectSeerr()
        }
    }

    private func forget(_ user: RememberedUser) {
        guard let server = appState.activeServer else { return }
        do {
            // forgetUser clears a default pin naming this profile itself, so no path can forget to.
            try dependencies.forgetUser(id: user.id, serverID: server.id)
            refresh()
        } catch {
            actionError = ErrorText.user(for: error)
        }
    }
}

// MARK: - Launch behavior labels

private extension AuthPreferences.LaunchBehavior {
    var label: String {
        switch self {
        case .showPicker:
            String(localized: "settings.profile.launch.picker",
                   defaultValue: "Show profile picker")
        case .useDefault:
            String(localized: "settings.profile.launch.default",
                   defaultValue: "Use default profile")
        }
    }

    var detail: String {
        switch self {
        case .showPicker:
            String(localized: "settings.profile.launch.picker.detail",
                   defaultValue: "Pick who's watching every time the app opens.")
        case .useDefault:
            String(localized: "settings.profile.launch.default.detail",
                   defaultValue: "Skip the picker and sign in as the default profile automatically.")
        }
    }
}

// MARK: - Reprompt interval labels

private extension AuthPreferences.ProfileRepromptInterval {
    var label: String {
        switch self {
        case .off:
            String(localized: "settings.profile.reprompt.off", defaultValue: "Never")
        case .immediately:
            String(localized: "settings.profile.reprompt.immediately", defaultValue: "Every time")
        case .after30s:
            String(localized: "settings.profile.reprompt.30s", defaultValue: "After 30 seconds")
        case .after1min:
            String(localized: "settings.profile.reprompt.1min", defaultValue: "After 1 minute")
        case .after5min:
            String(localized: "settings.profile.reprompt.5min", defaultValue: "After 5 minutes")
        case .after15min:
            String(localized: "settings.profile.reprompt.15min", defaultValue: "After 15 minutes")
        case .after60min:
            String(localized: "settings.profile.reprompt.60min", defaultValue: "After 1 hour")
        }
    }
}
