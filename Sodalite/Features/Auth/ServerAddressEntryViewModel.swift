import Foundation
import Observation

@Observable
final class ServerAddressEntryViewModel {
    var serverAddress = ""
    var isLoading = false
    var errorMessage: String?
    var discoveredServer: JellyfinServer?
    var showLogin = false
    /// Set instead of `errorMessage` for a certificate refusal, because that is the one connection
    /// failure on this screen the user can actually answer.
    var pendingTrust: PendingCertificateTrust?

    private let discoveryService: ServerDiscoveryServiceProtocol
    private let trustStore: ServerTrustStore

    init(discoveryService: ServerDiscoveryServiceProtocol, trustStore: ServerTrustStore) {
        self.discoveryService = discoveryService
        self.trustStore = trustStore
    }

    func connectToServer() async {
        guard !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isLoading = true
        errorMessage = nil
        pendingTrust = nil

        let result = await discoveryService.discoverServer(input: serverAddress)

        switch result {
        case .success(let url, let info):
            discoveredServer = JellyfinServer(
                id: info.id,
                name: info.serverName,
                url: url,
                version: info.version
            )
            showLogin = true
        case .failure(.certificateUntrusted(let host, let fingerprint)):
            pendingTrust = CertificateTrustPrompt.pending(host: host, fingerprint: fingerprint, trustStore: trustStore)
        case .failure(let error):
            errorMessage = ErrorText.user(for: error)
        }

        isLoading = false
    }

    /// Records the answer and acts on it. Storing the pin without retrying would leave the user on a
    /// screen that still says no to an address they just said yes to.
    func trustPendingCertificate() async {
        let pinned = CertificateTrustPrompt.pin(pendingTrust, trustStore: trustStore)
        pendingTrust = nil
        if pinned { await connectToServer() }
    }
}
