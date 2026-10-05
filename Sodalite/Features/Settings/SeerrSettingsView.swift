import SwiftUI

struct SeerrSettingsView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    @State private var serverAddressText: String = ""
    @State private var isDiscovering = false
    @State private var discoveredServer: SeerrServer?
    @State private var serverVersion: String?
    @State private var discoveryError: String?

    @State private var useJellyfinCredentials = true
    @State private var usernameText: String = ""
    @State private var passwordText: String = ""
    @State private var cachedJellyfinPassword: String?
    @State private var isLoggingIn = false
    @State private var loginError: String?

    @State private var showSuccess = false

    #if os(iOS)
    @State private var showEditURLs = false
    #endif

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 32) {
                    Text("settings.seerr.title")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)

                    if appState.isSeerrConnected {
                        connectedState
                    } else {
                        serverSection
                        if discoveredServer != nil {
                            credentialsSection
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .screenContentInset()
            }
            .animation(.easeInOut(duration: 0.3), value: discoveredServer)
            .animation(.easeInOut(duration: 0.3), value: appState.isSeerrConnected)

            if showSuccess {
                successOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSuccess)
        .hidesShellTabBar()
        // Inline header only; floating tvOS nav-title sits behind scrolling content. Matches PlaybackSettingsView.
        .hidesNavigationBarChrome()
        .onAppear(perform: bootstrap)
    }

    // MARK: - Server Section

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.seerr.section.server")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let server = discoveredServer {
                discoveredServerCard(server: server)
            } else {
                serverEntry
            }
        }
    }

    private var serverEntry: some View {
        VStack(spacing: 12) {
            TextField(
                String(localized: "settings.seerr.serverAddress.placeholder",
                       defaultValue: "IP or URL"),
                text: $serverAddressText
            )
            .textContentType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)

            if let jellyfinHost = appState.activeServer?.url.host {
                Button {
                    serverAddressText = jellyfinHost
                } label: {
                    Label("settings.seerr.useJellyfinIP", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                // foregroundStyle doesn't override the bordered style's tint into the icon; a custom buttonStyle is needed.
                .buttonStyle(SettingsTileButtonStyle())
            }

            if let discoveryError {
                Text(discoveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await discover() }
            } label: {
                if isDiscovering {
                    ProgressView()
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                } else {
                    Text("settings.seerr.connect")
                        .font(.body)
                        .fontWeight(.medium)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
            }
            // Primary action of the step: prominent so it is not lost against the backdrop.
            .buttonStyle(SettingsTileButtonStyle(isProminent: true))
            .disabled(isDiscovering || !isAddressValid)
        }
    }

    private func discoveredServerCard(server: SeerrServer) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.Theme.success)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.url.host ?? server.url.absoluteString)
                    .font(.body)
                    .fontWeight(.medium)
                if let serverVersion {
                    Text(verbatim: "v\(serverVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                discoveredServer = nil
                serverVersion = nil
                loginError = nil
                passwordText = ""
            } label: {
                Text("settings.seerr.changeServer")
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.05))
        )
    }

    // MARK: - Credentials Section

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.seerr.section.credentials")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasJellyfinUser {
                jellyfinToggle
            }

            VStack(spacing: 12) {
                if !isUsernameHidden {
                    TextField(
                        String(localized: "auth.login.username", defaultValue: "Username"),
                        text: $usernameText
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(useJellyfinCredentials && hasJellyfinUser)
                    .opacity(useJellyfinCredentials && hasJellyfinUser ? 0.6 : 1.0)
                }

                if isPasswordHidden {
                    passwordCachedNote
                } else {
                    if useJellyfinCredentials && hasJellyfinUser && cachedJellyfinPassword == nil {
                        passwordNeededNote
                    }
                    SecureField(
                        String(localized: "auth.login.password", defaultValue: "Password"),
                        text: $passwordText
                    )
                }

                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await login() }
                } label: {
                    if isLoggingIn {
                        ProgressView()
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    } else {
                        Text("settings.seerr.login")
                            .font(.body)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                }
                // The step that actually completes the setup; a faint tile here read as "done"
                // and users left the flow one tap early (Sodalite#82).
                .buttonStyle(SettingsTileButtonStyle(isProminent: true))
                .disabled(isLoggingIn || !canSubmit)
            }
        }
    }

    private var jellyfinToggle: some View {
        Button {
            useJellyfinCredentials.toggle()
            if useJellyfinCredentials, let jfName = appState.activeUser?.name {
                usernameText = jfName
            }
            passwordText = ""
            loginError = nil
        } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.seerr.useJellyfin")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("settings.seerr.useJellyfin.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(useJellyfinCredentials ? "common.on" : "common.off")
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(useJellyfinCredentials ? Color.Theme.success : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(useJellyfinCredentials ? Color.Theme.success.opacity(0.15) : Color.Theme.restFill)
                    )
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.05))
            )
        }
        // GhostTileButtonStyle adds only the focus stroke+lift, preserving the tile; .plain would tint the label + draw the white halo.
        .buttonStyle(GhostTileButtonStyle())
    }

    private var passwordCachedNote: some View {
        Label {
            Text("settings.seerr.passwordCached")
                .font(.caption)
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.Theme.success)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.Theme.success.opacity(0.08))
        )
    }

    /// Shown whenever the toggle is on but no password is cached. The app does not record how the
    /// user signed in, so this states the fact rather than guessing a cause (it used to blame Quick
    /// Connect, which was wrong for anyone whose password a profile switch had dropped).
    private var passwordNeededNote: some View {
        Label {
            Text("settings.seerr.passwordNeededNote")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.Theme.restFillFaint)
        )
    }

    // MARK: - Connected State

    private var connectedState: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.Theme.success)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.activeSeerrUser?.resolvedDisplayName ?? "")
                        .font(.body)
                        .fontWeight(.medium)
                    Text(appState.activeSeerrServer?.url.host ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.05))
            )

            myRequestsToggle

            #if os(iOS)
            // Admins can approve requests, so only they benefit from a pending-approval notification.
            if appState.activeSeerrUser?.canManageRequests == true {
                notificationsToggle
            }
            #endif

            #if os(iOS)
            Button {
                showEditURLs = true
            } label: {
                Label {
                    Text("multiServer.urls.edit", bundle: .main)
                } icon: {
                    Image(systemName: "link.badge.plus")
                }
                .font(.body)
                .fontWeight(.medium)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
            #endif

            Button {
                Task { await logout() }
            } label: {
                Label("settings.seerr.logout", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.body)
                    .fontWeight(.medium)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        #if os(iOS)
        .sheet(isPresented: $showEditURLs) {
            if let server = appState.activeSeerrServer {
                DualURLEditSheet(
                    title: "multiServer.urls.title",
                    internalPlaceholder: "multiServer.urls.internal.placeholder.seerr",
                    externalPlaceholder: "multiServer.urls.external.placeholder.seerr",
                    initialInternalURL: server.internalURL,
                    initialExternalURL: server.externalURL,
                    resolve: ServerAddressResolution.seerr(dependencies.seerrServerDiscoveryService),
                    onSave: { internalURL, externalURL in
                        try? dependencies.updateSeerrServerURLs(
                            internalURL: internalURL,
                            externalURL: externalURL
                        )
                    }
                )
            }
        }
        #endif
    }

    #if os(iOS)
    @State private var notifyDenied = false

    /// Setter kicks off the async permission flow and does NOT persist until granted, so the row only
    /// flips to On once iOS grants permission (and stays Off on denial).
    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { dependencies.seerrNotificationPreferences.notifyPendingRequests },
            set: { newValue in Task { await setNotifications(newValue) } }
        )
    }

    private var notificationsToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            ValuePickerRow(
                icon: "bell.badge",
                title: "catalog.notify.toggle.title",
                subtitle: "catalog.notify.toggle.subtitle",
                options: [true, false],
                selection: notifyBinding,
                label: { $0
                    ? String(localized: "common.on", defaultValue: "On")
                    : String(localized: "common.off", defaultValue: "Off") }
            )
            if notifyDenied {
                Text("catalog.notify.denied.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func setNotifications(_ enabled: Bool) async {
        let prefs = dependencies.seerrNotificationPreferences
        if enabled {
            let granted = await PendingRequestsNotifier.requestAuthorization()
            guard granted else {
                notifyDenied = true
                prefs.notifyPendingRequests = false
                return
            }
            notifyDenied = false
            prefs.notifyPendingRequests = true
            PendingRequestsBackgroundRefresh.schedule()
            await dependencies.pendingRequestsMonitor.refresh()
            let count = dependencies.pendingRequestsMonitor.pendingApprovalCount ?? 0
            // Baseline so enabling never retro-notifies about already-pending requests; only future rises fire.
            if let serverID = dependencies.activeServer?.id, let userID = dependencies.activeUserID {
                prefs.setLastSeenPendingCount(count, jellyfinServerID: serverID, jellyfinUserID: userID)
            }
            await dependencies.syncAppIconBadge()
        } else {
            prefs.notifyPendingRequests = false
            PendingRequestsBackgroundRefresh.cancel()
            await dependencies.syncAppIconBadge()
        }
    }
    #endif

    @State private var myRequestsDenied = false

    /// Per profile; the setter also refreshes so switching on records a fresh baseline right away.
    private var myRequestsBinding: Binding<Bool> {
        Binding(
            get: {
                guard let scope = dependencies.myRequestsScope else { return true }
                return dependencies.seerrNotificationPreferences.notifyMyRequests(scope: scope)
            },
            set: { enabled in
                dependencies.myRequestsWatcher.setEnabled(enabled)
                Task {
                    if enabled { await dependencies.myRequestsWatcher.refresh() }
                    await dependencies.syncAppIconBadge()
                }
            }
        )
    }

    private var myRequestsToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            ValuePickerRow(
                icon: "bell",
                title: "catalog.notify.mine.toggle.title",
                subtitle: "catalog.notify.mine.toggle.subtitle",
                options: [true, false],
                selection: myRequestsBinding,
                label: { $0
                    ? String(localized: "common.on", defaultValue: "On")
                    : String(localized: "common.off", defaultValue: "Off") }
            )
            if myRequestsDenied {
                Text("catalog.notify.mine.denied.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            myRequestsDenied = await MyRequestsNotifier.authorizationStatus() == .denied
        }
    }

    private var successOverlay: some View {
        VStack(spacing: 24) {
            Spacer()
            CheckmarkAnimation()
            Text("settings.seerr.success")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Theme.scrimHeavy)
    }

    // MARK: - Derived

    private var isAddressValid: Bool {
        !serverAddressText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasJellyfinUser: Bool {
        appState.activeUser != nil
    }

    private var isUsernameHidden: Bool {
        useJellyfinCredentials && hasJellyfinUser
    }

    private var isPasswordHidden: Bool {
        useJellyfinCredentials && hasJellyfinUser && cachedJellyfinPassword != nil
    }

    private var canSubmit: Bool {
        guard !isLoggingIn else { return false }
        if usernameText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isPasswordHidden { return true }
        return !passwordText.isEmpty
    }

    // MARK: - Actions

    private func bootstrap() {
        if let jfName = appState.activeUser?.name, usernameText.isEmpty {
            usernameText = jfName
        }
        cachedJellyfinPassword = dependencies.loadJellyfinPassword()
    }

    private func discover() async {
        let input = serverAddressText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }

        let result = await dependencies.seerrServerDiscoveryService.discoverServer(input: input)

        switch result {
        case .success(let url, let info):
            let server = SeerrServer(url: url)
            dependencies.seerrClient.baseURL = url
            discoveredServer = server
            serverVersion = info.version
        case .failure(let error):
            discoveryError = ErrorText.user(for: error)
        }
    }

    private func login() async {
        guard let server = discoveredServer else { return }

        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }

        let username = usernameText.trimmingCharacters(in: .whitespaces)
        let password: String = {
            if isPasswordHidden, let cached = cachedJellyfinPassword {
                return cached
            }
            return passwordText
        }()

        do {
            let user = try await dependencies.seerrAuthService.loginWithJellyfin(
                username: username,
                password: password
            )
            // Tie the Seerr session to the active Jellyfin profile (per-profile cookie) so switchToUser can restore it.
            // What comes back may carry the URL slot this sign-in did not know (Sodalite#45).
            let connected = try dependencies.saveSeerrSession(
                server: server,
                forJellyfinUserID: appState.activeUser?.id,
                jellyfinServerID: appState.activeServer?.id
            )

            // The password just typed here is the Jellyfin one, so keep it: this screen is the only
            // one that asks for it again, and without this it would ask on every reconnect.
            if useJellyfinCredentials, hasJellyfinUser, !passwordText.isEmpty,
               await dependencies.adoptJellyfinPassword(username: username, password: password) {
                cachedJellyfinPassword = password
            }

            passwordText = ""
            showSuccess = true

            try? await Task.sleep(for: .seconds(1.5))
            appState.setSeerrConnected(server: connected, user: user)
            dependencies.scheduleRouteResolve()
            showSuccess = false
        } catch {
            // Drop the cookie only, keep baseURL: full clearSeerrSession wipes baseURL -> next attempt fails on invalid URL.
            dependencies.seerrClient.sessionCookie = nil
            loginError = ErrorText.user(for: error)
        }
    }

    private func logout() async {
        do {
            try await dependencies.seerrAuthService.logout()
        } catch {
            #if DEBUG
            print("[SeerrSettings] remote logout failed (clearing local session anyway): \(error)")
            #endif
        }
        // Also drop the per-profile remembered cookie, else next launch restores the remembered entry and silently reconnects the logged-out account.
        if let userID = appState.activeUser?.id,
           let serverID = appState.activeServer?.id {
            dependencies.forgetRememberedSeerr(
                forJellyfinUserID: userID,
                jellyfinServerID: serverID
            )
        }
        try? dependencies.clearSeerrSession()
        appState.disconnectSeerr()
        discoveredServer = nil
        serverVersion = nil
        serverAddressText = ""
        passwordText = ""
    }
}
