import Foundation

nonisolated struct SeerrServerInfo: Codable, Sendable {
    let version: String
}

enum SeerrServerDiscoveryResult: Sendable {
    case success(url: URL, info: SeerrServerInfo)
    case failure(APIError)
}

private struct DiscoveredSeerr: Sendable {
    let info: SeerrServerInfo
    let url: URL
}

protocol SeerrServerDiscoveryServiceProtocol: Sendable {
    func discoverServer(input: String) async -> SeerrServerDiscoveryResult
}

final class SeerrServerDiscoveryService: SeerrServerDiscoveryServiceProtocol {
    private let httpClient: HTTPClientProtocol
    private let decoder: JSONDecoder

    nonisolated init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func discoverServer(input: String) async -> SeerrServerDiscoveryResult {
        let candidates = buildCandidateURLs(from: input)
        let started = ContinuousClock.now

        let statusPath = SeerrEndpoint.status.path

        let verdicts = await DiscoveryProbeRace.run(candidates: candidates) { [decoder, httpClient] url in
            await DiscoveryProbeRace.attempt(
                label: "seerr",
                url: url,
                describe: { (found: DiscoveredSeerr) in "v\(found.info.version)" }
            ) {
                let (data, response) = try await httpClient.requestData(
                    baseURL: url,
                    endpoint: SeerrEndpoint.status,
                    headers: ["Accept": "application/json"]
                )
                // An http address behind an upgrading proxy is stored as the https one, or the
                // sign-in POST turns into a GET on the 301 and the cookie travels in clear text
                // before every redirect (audit NET-207).
                return DiscoveredSeerr(
                    info: try decoder.decode(SeerrServerInfo.self, from: data),
                    url: DiscoveryCandidates.upgradedBaseURL(
                        candidate: url, finalURL: response.url, endpointPath: statusPath)
                )
            }
        }

        for verdict in verdicts {
            guard case .success(let found) = verdict else { continue }
            LogTap.shared.note("[discovery] seerr resolved \(found.url.absoluteString) in \(DiscoveryProbeRace.elapsedText(since: started))")
            return .success(url: found.url, info: found.info)
        }

        DiscoveryProbeRace.logUnanswered(
            label: "seerr",
            candidates: candidates,
            verdicts: verdicts,
            since: started
        )
        LogTap.shared.note("[discovery] seerr failed after \(DiscoveryProbeRace.elapsedText(since: started)) over \(candidates.count) candidate(s)")
        return .failure(DiscoveryProbeRace.aggregateError(verdicts))
    }

    func buildCandidateURLs(from input: String) -> [URL] {
        DiscoveryCandidates.build(from: input, ports: .seerr)
    }
}
