import Foundation

protocol ServerDiscoveryServiceProtocol: Sendable {
    func discoverServer(input: String) async -> ServerDiscoveryResult
}

enum ServerDiscoveryResult: Sendable {
    case success(url: URL, serverInfo: ServerDiscoveryInfo)
    case failure(APIError)
}

struct ServerDiscoveryInfo: Sendable {
    let id: String
    let serverName: String
    let version: String
}

private struct DiscoveredJellyfin: Sendable {
    let info: ServerDiscoveryInfo
    let url: URL
}

final class ServerDiscoveryService: ServerDiscoveryServiceProtocol {
    private let httpClient: HTTPClientProtocol

    nonisolated init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient
    }

    func discoverServer(input: String) async -> ServerDiscoveryResult {
        let candidates = buildCandidateURLs(from: input)
        let started = ContinuousClock.now
        let infoPath = JellyfinEndpoint.publicInfo.path

        let verdicts = await DiscoveryProbeRace.run(candidates: candidates) { [httpClient] url in
            await DiscoveryProbeRace.attempt(
                label: "jellyfin",
                url: url,
                describe: { (found: DiscoveredJellyfin) in "\(found.info.serverName) v\(found.info.version)" }
            ) {
                let (data, response) = try await httpClient.requestData(
                    baseURL: url,
                    endpoint: JellyfinEndpoint.publicInfo,
                    headers: ["Accept": "application/json"]
                )
                let serverInfo: JellyfinPublicServerInfo
                do {
                    serverInfo = try JSONDecoder().decode(JellyfinPublicServerInfo.self, from: data)
                } catch {
                    throw APIError.decodingError(error)
                }
                // Only a decodable connection gates discovery; missing optional metadata must not.
                let info = ServerDiscoveryInfo(
                    id: serverInfo.id ?? "",
                    serverName: serverInfo.serverName ?? "Jellyfin",
                    version: serverInfo.version ?? ""
                )
                return DiscoveredJellyfin(
                    info: info,
                    url: DiscoveryCandidates.upgradedBaseURL(candidate: url, finalURL: response.url, endpointPath: infoPath)
                )
            }
        }

        for verdict in verdicts {
            guard case .success(let found) = verdict else { continue }
            LogTap.shared.note("[discovery] jellyfin resolved \(found.url.absoluteString) in \(DiscoveryProbeRace.elapsedText(since: started))")
            return .success(url: found.url, serverInfo: found.info)
        }

        DiscoveryProbeRace.logUnanswered(
            label: "jellyfin",
            candidates: candidates,
            verdicts: verdicts,
            since: started
        )
        LogTap.shared.note("[discovery] jellyfin failed after \(DiscoveryProbeRace.elapsedText(since: started)) over \(candidates.count) candidate(s)")
        return .failure(DiscoveryProbeRace.aggregateError(verdicts))
    }

    // Widened from private to internal so SodaliteTests can exercise the URL-candidate branches directly.
    func buildCandidateURLs(from input: String) -> [URL] {
        DiscoveryCandidates.build(from: input, ports: .jellyfin)
    }
}
