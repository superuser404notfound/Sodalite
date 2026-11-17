import Testing
import Foundation
@testable import Sodalite

/// Characterizes ServerDiscoveryService.buildCandidateURLs, the branchiest pure function gating connectivity.
@MainActor
struct ServerDiscoveryURLTests {
    private func candidates(_ input: String) -> [String] {
        ServerDiscoveryService().buildCandidateURLs(from: input).map(\.absoluteString)
    }

    @Test func explicitHTTPSNoPortNoPath_addsDefaultPort() {
        #expect(candidates("https://jelly.example.com") == [
            "https://jelly.example.com",
            "https://jelly.example.com:8920",
        ])
    }

    @Test func explicitHTTPNoPortNoPath_addsDefaultPort() {
        #expect(candidates("http://jelly.example.com") == [
            "http://jelly.example.com",
            "http://jelly.example.com:8096",
        ])
    }

    @Test func explicitSchemeWithBasePath_doesNotAppendPort() {
        // A base path means reverse proxy; default ports must not glue onto it.
        #expect(candidates("https://jelly.example.com/jellyfin") == [
            "https://jelly.example.com/jellyfin",
        ])
    }

    @Test func explicitSchemeWithPort_isLeftAlone() {
        #expect(candidates("https://jelly.example.com:9999") == [
            "https://jelly.example.com:9999",
        ])
    }

    @Test func trailingSlashAndWhitespace_areTrimmed() {
        #expect(candidates("  https://jelly.example.com/  ") == [
            "https://jelly.example.com",
            "https://jelly.example.com:8920",
        ])
    }

    @Test func ipWithoutPort_ordersDefaultPortsThenStandard() {
        #expect(candidates("192.168.1.50") == [
            "https://192.168.1.50:8920",
            "http://192.168.1.50:8096",
            "https://192.168.1.50",
            "http://192.168.1.50",
        ])
    }

    @Test func ipWithPort_doesNotDoublePort() {
        #expect(candidates("192.168.1.50:8096") == [
            "https://192.168.1.50:8096",
            "http://192.168.1.50:8096",
        ])
    }

    @Test func hostnameNoPortNoPath_standardThenDefaultPorts() {
        #expect(candidates("jelly.example.com") == [
            "https://jelly.example.com",
            "http://jelly.example.com",
            "https://jelly.example.com:8920",
            "http://jelly.example.com:8096",
        ])
    }

    @Test func hostnameWithPath_skipsPortVariants() {
        #expect(candidates("jelly.example.com/jellyfin") == [
            "https://jelly.example.com/jellyfin",
            "http://jelly.example.com/jellyfin",
        ])
    }

    @Test func emptyInput_yieldsNoHostedCandidate() {
        // Degenerate input must never surface a candidate with a real (non-empty) host.
        #expect(ServerDiscoveryService().buildCandidateURLs(from: "   ").allSatisfy { ($0.host() ?? "").isEmpty })
    }

    // MARK: Redirect adoption (audit NETWORK-4)

    private func upgraded(_ candidate: String, _ final: String?) -> String {
        DiscoveryCandidates.upgradedBaseURL(
            candidate: URL(string: candidate)!,
            finalURL: final.flatMap(URL.init(string:)),
            endpointPath: "/System/Info/Public"
        ).absoluteString
    }

    @Test func httpToHTTPSUpgradeOnSameHost_isAdopted() {
        #expect(upgraded("http://jf.example.com", "https://jf.example.com/System/Info/Public")
            == "https://jf.example.com")
        #expect(upgraded("http://jf.example.com/jellyfin", "https://JF.example.com:8443/jellyfin/System/Info/Public")
            == "https://JF.example.com:8443/jellyfin")
    }

    @Test func anyOtherRedirect_keepsTheTypedAddress() {
        #expect(upgraded("http://jf.example.com", nil) == "http://jf.example.com")
        #expect(upgraded("http://jf.example.com", "https://other.example.com/System/Info/Public")
            == "http://jf.example.com")
        #expect(upgraded("https://jf.example.com", "http://jf.example.com/System/Info/Public")
            == "https://jf.example.com")
        #expect(upgraded("http://jf.example.com", "https://jf.example.com/login?next=/System/Info/Public")
            == "http://jf.example.com")
    }

    // MARK: Seerr shares the builder (audit NET-R201, NET-207)

    private func seerrCandidates(_ input: String) -> [String] {
        SeerrServerDiscoveryService().buildCandidateURLs(from: input).map(\.absoluteString)
    }

    @Test func seerrKeepsItsOwnDefaultPorts() {
        #expect(seerrCandidates("192.168.1.10") == [
            "http://192.168.1.10:5055", "https://192.168.1.10:5055",
            "https://192.168.1.10", "http://192.168.1.10",
        ])
        #expect(seerrCandidates("requests.example.com") == [
            "https://requests.example.com", "http://requests.example.com",
            "http://requests.example.com:5055", "https://requests.example.com:5055",
        ])
        #expect(seerrCandidates("http://requests.example.com") == [
            "http://requests.example.com", "http://requests.example.com:5055",
        ])
        #expect(seerrCandidates("https://requests.example.com") == ["https://requests.example.com"])
        #expect(seerrCandidates("requests.example.com:5055") == [
            "https://requests.example.com:5055", "http://requests.example.com:5055",
        ])
    }

    /// The Seerr twin stored the typed http address behind an upgrading proxy, so the sign-in POST
    /// turned into a GET on the 301 (audit NET-207).
    @Test func seerrStoresTheHTTPSAddressItWasUpgradedTo() async throws {
        let http = UpgradingStatusClient(finalURL: URL(string: "https://requests.example.com/api/v1/status")!)
        let service = SeerrServerDiscoveryService(httpClient: http)

        let result = await service.discoverServer(input: "http://requests.example.com")

        guard case .success(let url, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(url.absoluteString == "https://requests.example.com")
    }
}

/// Answers every status probe as if a proxy had upgraded it to `finalURL`.
private final class UpgradingStatusClient: HTTPClientProtocol, @unchecked Sendable {
    let finalURL: URL
    init(finalURL: URL) { self.finalURL = finalURL }

    func request<T: Decodable>(
        baseURL: URL, endpoint: APIEndpoint, headers: [String: String], responseType: T.Type
    ) async throws -> T {
        throw APIError.invalidResponse
    }

    func request(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws {}

    func requestData(
        baseURL: URL, endpoint: APIEndpoint, headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        guard baseURL.port == nil else { throw APIError.serverUnreachable }
        let body = Data(#"{"version":"2.7.0"}"#.utf8)
        return (body, HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
