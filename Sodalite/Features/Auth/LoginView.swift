import SwiftUI

struct LoginView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: LoginViewModel?
    @State private var showQuickConnect = false
    @State private var showSuccess = false
    #if os(iOS)
    @FocusState private var focusedField: Field?
    #endif
    #if os(iOS)
    @Environment(\.appearanceTheme) private var appearanceTheme
    @State private var promptServer: JellyfinServer?
    @State private var showAddURLDialog = false
    @State private var showAddURLSheet = false
    #endif

    let server: JellyfinServer
    /// Nil means "Sign in manually": show the full form including the username field.
    var preSelectedUser: JellyfinUser? = nil
    var addMode: Bool = false
    var onCompletion: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if showSuccess {
                successOverlay
                    .transition(.opacity)
            } else {
                loginContent
                    .transition(.opacity)
            }
            #if os(iOS)
            if showAddURLDialog {
                addURLPromptOverlay
                    .transition(.opacity)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: showSuccess)
        #if os(iOS)
        .animation(.easeInOut(duration: 0.25), value: showAddURLDialog)
        #endif
        .onAppear {
            if viewModel == nil {
                viewModel = LoginViewModel(
                    server: server,
                    preSelectedUser: preSelectedUser,
                    dependencies: dependencies
                )
            }
        }
        // Keyed on the view model's arrival: it is built in onAppear, which is not ordered against
        // this task, and the route belongs to the sign-in client it owns.
        .task(id: viewModel != nil) {
            // The view model pins an optimistic address in its init so the first frame has one; this
            // is the probe that corrects it. Reached directly (a server with one profile, a deep
            // link) the picker's own resolve never ran, and without this the sign-in would spend its
            // whole life on the last route that worked, which away from home is the LAN address.
            guard let viewModel else { return }
            await dependencies.resolveSignInRoute(for: server, client: viewModel.signInClient)
        }
        .onDisappear {
            viewModel?.stopQuickConnect()
        }
        #if os(iOS)
        .sheet(isPresented: $showAddURLSheet, onDismiss: { proceedAfterAuth() }) {
            if let server = promptServer, let slot = server.emptyURLSlot {
                AddSecondURLSheet(
                    slot: slot,
                    knownURL: server.url,
                    resolve: ServerAddressResolution.jellyfin(dependencies.serverDiscoveryService),
                    onSave: { newURL in
                        let merged = server.urls(filling: slot, with: newURL)
                        try? dependencies.updateServerURLs(
                            serverID: server.id,
                            internalURL: merged.internal,
                            externalURL: merged.external
                        )
                    }
                )
            }
        }
        #endif
    }

    #if os(iOS)
    private var addURLDialogTitle: LocalizedStringKey {
        guard let slot = promptServer?.emptyURLSlot else { return "" }
        return slot == .internal
            ? "multiServer.addURL.dialog.title.internal"
            : "multiServer.addURL.dialog.title.external"
    }

    private var addURLPromptOverlay: some View {
        ZStack {
            Color.Theme.scrim
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Text(addURLDialogTitle, bundle: .main)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("multiServer.addURL.dialog.message", bundle: .main)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    Button {
                        showAddURLSheet = true
                    } label: {
                        Text("multiServer.addURL.dialog.add", bundle: .main)
                            .font(.headline)
                            .foregroundStyle(appearanceTheme.palette.foreground.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Button {
                        proceedAfterAuth()
                    } label: {
                        Text("multiServer.addURL.dialog.notNow", bundle: .main)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(32)
        }
    }
    #endif

    private var loginContent: some View {
        Group {
            #if os(iOS)
            touchLoginContent
            #elseif os(tvOS)
            tvLoginContent
            #else
            focusLoginContent
            #endif
        }
        .onChange(of: viewModel?.loginSucceeded) { _, succeeded in
            if succeeded == true {
                showSuccessAndFinalize()
            }
        }
    }

    private var focusLoginContent: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 12) {
                if let preSelectedUser {
                    userAvatar(for: preSelectedUser)
                }

                Text(preSelectedUser?.name ?? server.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("auth.login.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let vm = viewModel {
                if showQuickConnect {
                    quickConnectSection(vm: vm)
                } else {
                    loginFormSection(vm: vm)
                }
            }

            Spacer()
        }
        .padding()
    }

    #if os(tvOS)
    private var tvLoginContent: some View {
        TVOnboardingLayout(
            title: Text(verbatim: preSelectedUser?.name ?? server.name),
            subtitle: Text("auth.login.subtitle")
        ) {
            if let preSelectedUser {
                userAvatar(for: preSelectedUser, diameter: 140)
            } else {
                TVOnboardingLogo()
            }
        } content: {
            if let vm = viewModel {
                if showQuickConnect {
                    tvQuickConnect(vm: vm)
                } else {
                    // Username already in the title when picked from the user grid.
                    if preSelectedUser == nil {
                        TextField(String(localized: "auth.login.username"), text: Bindable(vm).username)
                            .verbatimTextEntry()
                    }
                    SecureField(String(localized: "auth.login.password"), text: Bindable(vm).password)

                    if let error = vm.errorMessage {
                        TVOnboardingFootnote(text: Text(verbatim: error), isError: true)
                    }

                    TVOnboardingPrimaryButton(title: "auth.login.signIn", isLoading: vm.isLoading) {
                        Task { await vm.login() }
                    }
                    .disabled(vm.isLoading || vm.username.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, 8)

                    // Equal to Sign In here, not a link under it: typing a password with the remote
                    // is the slow way in, confirming a code on the phone the quick one.
                    TVOnboardingPillButton(title: "auth.login.quickConnect") {
                        showQuickConnect = true
                        Task { await vm.startQuickConnect() }
                    }
                }
            }
        }
    }

    private func tvQuickConnect(vm: LoginViewModel) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 20) {
                Text("auth.quickConnect.title")
                    .font(.headline)
                if let code = vm.quickConnectCode {
                    Text("auth.quickConnect.instruction")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 88, weight: .bold, design: .monospaced))
                    if vm.isPollingQuickConnect {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("auth.quickConnect.waiting")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if vm.isLoading {
                        ProgressView()
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(36)
            .background(Color.Theme.restFill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
            }

            if let error = vm.errorMessage {
                TVOnboardingFootnote(text: Text(verbatim: error), isError: true)
            }

            TVOnboardingPillButton(title: "auth.quickConnect.cancel") {
                vm.stopQuickConnect()
                showQuickConnect = false
            }
        }
    }
    #endif

    #if os(iOS)
    private enum Field { case username, password }

    private var touchLoginContent: some View {
        OnboardingScaffold(
            title: Text(verbatim: preSelectedUser?.name ?? server.name),
            subtitle: Text("auth.login.subtitle")
        ) {
            if let preSelectedUser {
                userAvatar(for: preSelectedUser, diameter: 112)
            } else {
                OnboardingLogo()
            }
        } content: {
            if let vm = viewModel {
                if showQuickConnect {
                    touchQuickConnect(vm: vm)
                } else {
                    touchCredentials(vm: vm)
                }
                if let error = vm.errorMessage {
                    OnboardingFootnote(text: Text(verbatim: error), isError: true)
                }
            }
        } actions: {
            if let vm = viewModel {
                if showQuickConnect {
                    OnboardingSecondaryButton(title: "auth.quickConnect.cancel") {
                        vm.stopQuickConnect()
                        showQuickConnect = false
                    }
                } else {
                    OnboardingPrimaryButton(title: "auth.login.signIn", isLoading: vm.isLoading) {
                        Task { await vm.login() }
                    }
                    .disabled(!canSignIn(vm) && !vm.isLoading)
                    OnboardingSecondaryButton(title: "auth.login.quickConnect") {
                        focusedField = nil
                        showQuickConnect = true
                        Task { await vm.startQuickConnect() }
                    }
                }
            }
        }
        .onAppear {
            focusedField = preSelectedUser == nil ? .username : .password
        }
    }

    private func canSignIn(_ vm: LoginViewModel) -> Bool {
        !vm.isLoading && !vm.username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func touchCredentials(vm: LoginViewModel) -> some View {
        OnboardingCard {
            // Username already in the title when picked from the user grid.
            if preSelectedUser == nil {
                HStack(spacing: 12) {
                    Image(systemName: "person")
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    TextField(String(localized: "auth.login.username"), text: Bindable(vm).username)
                        .verbatimTextEntry()
                        .textContentType(.username)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                }
                .padding(16)
                OnboardingCardDivider(leadingInset: 54)
            }
            HStack(spacing: 12) {
                Image(systemName: "lock")
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                SecureField(String(localized: "auth.login.password"), text: Bindable(vm).password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        guard canSignIn(vm) else { return }
                        Task { await vm.login() }
                    }
            }
            .padding(16)
        }
    }

    private func touchQuickConnect(vm: LoginViewModel) -> some View {
        OnboardingCard {
            VStack(spacing: 14) {
                Text("auth.quickConnect.title")
                    .font(.headline)
                if let code = vm.quickConnectCode {
                    Text("auth.quickConnect.instruction")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if vm.isPollingQuickConnect {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("auth.quickConnect.waiting")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if vm.isLoading {
                        ProgressView()
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }
    #endif

    // Identical composition to the UserPicker card so the transition reads as "same user, now enter password".
    @ViewBuilder
    private func userAvatar(for user: JellyfinUser, diameter: CGFloat = 140) -> some View {
        // On the server being signed in to and without a token, like the picker card: the live
        // session's host and token belong to another server.
        let url = viewModel.flatMap { vm in
            vm.signInClient.baseURL.flatMap { base in
                dependencies.jellyfinImageService.userProfileImageURL(
                    userID: user.id, tag: user.primaryImageTag, baseURL: base, token: nil)
            }
        }
        ZStack {
            if let url {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsCircle(for: user.name)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            } else {
                initialsCircle(for: user.name)
                    .frame(width: diameter, height: diameter)
            }
        }
    }

    private func initialsCircle(for name: String) -> some View {
        let parts = name.split(separator: " ")
        let initials: String = {
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }()
        return ZStack {
            Circle().fill(.ultraThinMaterial)
            Text(initials)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private var successOverlay: some View {
        VStack(spacing: 24) {
            Spacer()
            CheckmarkAnimation()
            if let user = viewModel?.authResult?.user {
                Text("auth.login.welcome \(user.name)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func loginFormSection(vm: LoginViewModel) -> some View {
        VStack(spacing: 20) {
            // Username already shown above when picked from the user-grid.
            if preSelectedUser == nil {
                TextField(String(localized: "auth.login.username"), text: Bindable(vm).username)
                    .verbatimTextEntry()
            }

            SecureField(String(localized: "auth.login.password"), text: Bindable(vm).password)

            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await vm.login() }
            } label: {
                if vm.isLoading {
                    ProgressView()
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                } else {
                    Text("auth.login.signIn")
                        .font(.body)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
            }
            // Primary action; Quick Connect below stays secondary.
            .buttonStyle(SettingsTileButtonStyle(isProminent: true))
            .disabled(vm.isLoading || vm.username.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                showQuickConnect = true
                Task { await vm.startQuickConnect() }
            } label: {
                Text("auth.login.quickConnect")
                    .font(.body)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: 500)
    }

    @ViewBuilder
    private func quickConnectSection(vm: LoginViewModel) -> some View {
        VStack(spacing: 20) {
            Text("auth.quickConnect.title")
                .font(.title3)

            if let code = vm.quickConnectCode {
                Text("auth.quickConnect.instruction")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .padding()

                if vm.isPollingQuickConnect {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("auth.quickConnect.waiting")
                            .foregroundStyle(.secondary)
                    }
                } else if vm.isLoading {
                    ProgressView()
                }
            } else {
                ProgressView()
            }

            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                vm.stopQuickConnect()
                showQuickConnect = false
            } label: {
                Text("auth.quickConnect.cancel")
                    .font(.body)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: 500)
    }

    private func showSuccessAndFinalize() {
        guard let vm = viewModel else { return }

        do {
            try vm.finalizeAuth()
        } catch {
            vm.errorMessage = ErrorText.user(for: error)
            vm.loginSucceeded = false
            return
        }

        showSuccess = true

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard let result = vm.authResult else { return }

            #if os(iOS)
            // Offer the missing internal/external URL once per server, before the
            // authenticated root swap so LoginView stays mounted for the prompt.
            if result.server.emptyURLSlot != nil,
               !DualURLPromptLatch.hasOffered(serverID: result.server.id) {
                DualURLPromptLatch.markOffered(serverID: result.server.id)
                promptServer = result.server
                withAnimation { showAddURLDialog = true }
                return
            }
            #endif

            proceedAfterAuth()
        }
    }

    private func proceedAfterAuth() {
        guard let result = viewModel?.authResult else { return }

        #if os(iOS)
        showAddURLDialog = false
        #endif

        // Persistence already happened in finalizeAuth -> saveSession; old addServer/pointer writes here were no-ops.
        appState.setAuthenticated(server: result.server, user: result.user)

        Task {
            // Re-evaluate Seerr against the new user. Add-mode needs this too, else it inherits the previous profile's Seerr state.
            await syncSeerrToActiveProfile(
                userID: result.user.id,
                serverID: result.server.id
            )

            // Needed by the "Add another profile" branch (stays mounted on TabRootView until popped); first-run relies on AppRouter swapping its root on isAuthenticated.
            NotificationCenter.default.post(name: .loginDidComplete, object: nil)

            // Add-mode hook (refresh Settings server list); nil in first-run.
            onCompletion?()
        }
    }

    /// Restores the just-authed profile's Seerr session from keychain (or wipes it). Mirrors ProfileSettingsView.restoreSeerrForSwitchedProfile.
    private func syncSeerrToActiveProfile(userID: String, serverID: String) async {
        await dependencies.applySeerrSession(
            forJellyfinUserID: userID,
            jellyfinServerID: serverID
        )
    }
}
