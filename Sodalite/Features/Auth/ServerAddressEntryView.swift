import SwiftUI

/// Manual Jellyfin address entry. Requires an enclosing NavigationStack (pushed from ServerDiscoveryView).
struct ServerAddressEntryView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: ServerAddressEntryViewModel?

    var addMode: Bool = false
    var onCompletion: (() -> Void)? = nil

    @FocusState private var addressFocused: Bool

    var body: some View {
        screen
            .onAppear {
                if viewModel == nil {
                    viewModel = ServerAddressEntryViewModel(
                        discoveryService: dependencies.serverDiscoveryService,
                        trustStore: dependencies.serverTrustStore
                    )
                }
            }
    }

    @ViewBuilder
    private var screen: some View {
        #if os(iOS)
        touchScreen
        #elseif os(tvOS)
        tvScreen
        #else
        focusScreen
        #endif
    }

    private var focusScreen: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 24) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)

                VStack(spacing: 8) {
                    Text("auth.server.title")
                        .font(.title2)

                    Text("auth.server.subtitle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let vm = viewModel {
                VStack(spacing: 20) {
                    TextField(String(localized: "auth.server.placeholder"), text: Bindable(vm).serverAddress)
                        .textFieldStyle(.automatic)
                        .autocorrectionDisabled()
                        // Unguarded: both modifiers exist on tvOS (15.0 / 13.0), and without them
                        // the on-screen keyboard keeps UIKit's .sentences default and opens on
                        // shift, which is wrong for every address and credential field we have.
                        .verbatimTextEntry(.url)

                    if let error = vm.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await vm.connectToServer() }
                    } label: {
                        if vm.isLoading {
                            ProgressView()
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                        } else {
                            Text("auth.server.connect")
                                .font(.body)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                        }
                    }
                    // Primary action of the screen.
                    .buttonStyle(SettingsTileButtonStyle(isProminent: true))
                    .disabled(vm.isLoading || vm.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)

                    // Below the primary action, not beside the error: the error is what raises the
                    // question, but the connect button has to keep the first focus move under it.
                    if vm.errorMessage != nil {
                        DiagnosticLogLink()
                    }
                }
                .frame(maxWidth: 500)
                .menuPresentation(item: Bindable(vm).pendingTrust) { pending in
                    CertificateTrustSheet(
                        pending: pending,
                        serverAddress: vm.serverAddress,
                        onTrust: { Task { await vm.trustPendingCertificate() } },
                        onCancel: { vm.pendingTrust = nil }
                    )
                }
                .navigationDestination(isPresented: Bindable(vm).showLogin) {
                    if let server = vm.discoveredServer {
                        UserPickerView(server: server, addMode: addMode, onCompletion: onCompletion)
                            .themedNavigationDestination()
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(iOS)
    private var canConnect: Bool {
        guard let vm = viewModel else { return false }
        return !vm.isLoading && !vm.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var touchScreen: some View {
        OnboardingScaffold(
            title: Text("auth.server.title"),
            subtitle: Text("auth.server.subtitle")
        ) {
            if let vm = viewModel {
                OnboardingCard {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        TextField(String(localized: "auth.server.placeholder"), text: Bindable(vm).serverAddress)
                            .autocorrectionDisabled()
                            .verbatimTextEntry(.url)
                            .submitLabel(.go)
                            .focused($addressFocused)
                            .onSubmit {
                                guard canConnect else { return }
                                Task { await vm.connectToServer() }
                            }
                    }
                    .padding(16)
                }
                .menuPresentation(item: Bindable(vm).pendingTrust) { pending in
                    CertificateTrustSheet(
                        pending: pending,
                        serverAddress: vm.serverAddress,
                        onTrust: { Task { await vm.trustPendingCertificate() } },
                        onCancel: { vm.pendingTrust = nil }
                    )
                }
                .navigationDestination(isPresented: Bindable(vm).showLogin) {
                    if let server = vm.discoveredServer {
                        UserPickerView(server: server, addMode: addMode, onCompletion: onCompletion)
                            .themedNavigationDestination()
                    }
                }

                if let error = vm.errorMessage {
                    OnboardingFootnote(text: Text(verbatim: error), isError: true)
                    DiagnosticLogLink(style: .inline)
                }
            }
        } actions: {
            OnboardingPrimaryButton(title: "auth.server.connect", isLoading: viewModel?.isLoading ?? false) {
                guard let vm = viewModel else { return }
                Task { await vm.connectToServer() }
            }
            .disabled(!canConnect && viewModel?.isLoading != true)
        }
        .onAppear { addressFocused = true }
    }
    #endif

    #if os(tvOS)
    private var tvScreen: some View {
        TVOnboardingSplit(
            title: Text("auth.server.title"),
            subtitle: Text("auth.server.subtitle")
        ) {
            if let vm = viewModel {
                TextField(String(localized: "auth.server.placeholder"), text: Bindable(vm).serverAddress)
                    .autocorrectionDisabled()
                    .verbatimTextEntry(.url)
                    .submitLabel(.go)
                    .onSubmit {
                        guard !vm.isLoading, !vm.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        Task { await vm.connectToServer() }
                    }
                    .menuPresentation(item: Bindable(vm).pendingTrust) { pending in
                        CertificateTrustSheet(
                            pending: pending,
                            serverAddress: vm.serverAddress,
                            onTrust: { Task { await vm.trustPendingCertificate() } },
                            onCancel: { vm.pendingTrust = nil }
                        )
                    }
                    .navigationDestination(isPresented: Bindable(vm).showLogin) {
                        if let server = vm.discoveredServer {
                            UserPickerView(server: server, addMode: addMode, onCompletion: onCompletion)
                                .themedNavigationDestination()
                        }
                    }

                if let error = vm.errorMessage {
                    TVOnboardingFootnote(text: Text(verbatim: error), isError: true)
                }

                TVOnboardingPrimaryButton(title: "auth.server.connect", isLoading: vm.isLoading) {
                    Task { await vm.connectToServer() }
                }
                .disabled(vm.isLoading || vm.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 8)

                if vm.errorMessage != nil {
                    DiagnosticLogLink(style: .inline)
                }
            }
        }
    }
    #endif
}
