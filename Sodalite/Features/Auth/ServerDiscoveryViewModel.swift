import Foundation
import Observation

@Observable
@MainActor
final class ServerDiscoveryViewModel {
    enum Phase { case scanning, results, empty }

    private(set) var phase: Phase = .scanning
    private(set) var servers: [DiscoveredServer] = []
    var isConnecting = false
    var errorMessage: String?
    /// A certificate this screen has been refused by and not yet been answered about. Set instead of
    /// `errorMessage`, for the same reason as on the manual-address screen: the user can answer this
    /// one, and an error line has nowhere to answer it.
    var pendingTrust: PendingCertificateTrust?

    let knownServerIDs: Set<String>
    private let discovery: JellyfinServerDiscoveryProtocol
    private let discoveryService: ServerDiscoveryServiceProtocol
    private let trustStore: ServerTrustStore
    /// The server the pending question is about, so accepting can ask it again.
    private var pendingServer: DiscoveredServer?

    init(
        discovery: JellyfinServerDiscoveryProtocol,
        discoveryService: ServerDiscoveryServiceProtocol,
        knownServerIDs: Set<String>,
        trustStore: ServerTrustStore
    ) {
        self.discovery = discovery
        self.discoveryService = discoveryService
        self.knownServerIDs = knownServerIDs
        self.trustStore = trustStore
    }

    func scan() async {
        servers = []
        phase = .scanning
        for await server in discovery.discover() where !servers.contains(where: { $0.id == server.id }) {
            servers.append(server)
            phase = .results
        }
        if servers.isEmpty { phase = .empty }
    }

    /// Runs the discovered address through the existing probe so we recover id/name/version and reuse the login flow.
    func selectServer(_ discovered: DiscoveredServer) async -> JellyfinServer? {
        // A second tap while the probe runs would push a second login flow (ASD-205).
        guard !isConnecting else { return nil }
        isConnecting = true
        errorMessage = nil
        pendingTrust = nil
        defer { isConnecting = false }

        let result = await discoveryService.discoverServer(input: discovered.address.absoluteString)
        switch result {
        case .success(let url, let info):
            // Found on the local network: pin to the internal slot regardless of hostname shape.
            return JellyfinServer(id: info.id, name: info.serverName, internalURL: url, externalURL: nil, version: info.version)
        case .failure(.certificateUntrusted(let host, let fingerprint)):
            pendingServer = discovered
            pendingTrust = CertificateTrustPrompt.pending(host: host, fingerprint: fingerprint, trustStore: trustStore)
            return nil
        case .failure(let error):
            errorMessage = ErrorText.user(for: error)
            return nil
        }
    }

    /// Records the answer and asks the same server again, so accepting lands on the login screen
    /// rather than back on a list that still refuses.
    func trustPendingCertificate() async -> JellyfinServer? {
        let discovered = pendingServer
        let pinned = CertificateTrustPrompt.pin(pendingTrust, trustStore: trustStore)
        pendingTrust = nil
        pendingServer = nil
        guard pinned, let discovered else { return nil }
        return await selectServer(discovered)
    }

    func isAlreadyAdded(_ server: DiscoveredServer) -> Bool {
        knownServerIDs.contains(server.id)
    }
}
