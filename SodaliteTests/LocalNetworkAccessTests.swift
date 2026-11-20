import Testing
import Foundation
import Network
@testable import Sodalite

/// Sodalite#92. The probe needs a device to answer, so what is pinned here is everything that
/// decides whether the probe is asked at all, plus the two readings it interprets.
///
/// That split is the point. The pre-filter is what stands between an honest error and an accusation
/// against the user's device, and it is the half that can be got wrong quietly: widen it and a phone
/// in flight mode is told its Local Network permission is off, which is a worse sentence than the
/// vague one it replaced.
struct LocalNetworkAccessTests {

    private static func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private static let offline = URLError(.notConnectedToInternet)

    // MARK: What the permission governs

    @Test(arguments: [
        "http://10.20.30.108:8096",
        "http://192.168.1.50:8096",
        "http://172.16.4.4:8096",
        "http://172.31.255.1:8096",
        "http://169.254.10.2:8096",
        "http://jellyfin.local:8096",
        "http://nas.lan:8096",
        "http://jellyfin:8096",
        "http://[fd00::1]:8096",
        "http://[fe80::1]:8096",
    ])
    func lanAddressesAreGoverned(_ address: String) {
        #expect(LocalNetworkAccess.isGoverned(Self.url(address)))
    }

    /// Loopback is the trap. `ServerURLClassifier` counts 127.0.0.1 as internal for its own purpose,
    /// which is right there and wrong here: talking to yourself needs no permission, so a loopback
    /// failure that got blamed on Local Network would send the reader to a switch that changes
    /// nothing.
    @Test(arguments: [
        "http://127.0.0.1:8096",
        "http://localhost:8096",
        "http://[::1]:8096",
        "https://jellyfin.example.com",
        "https://100.64.1.2:8096",
        "https://8.8.8.8",
    ])
    func addressesOutsideThePermissionAreNotGoverned(_ address: String) {
        #expect(!LocalNetworkAccess.isGoverned(Self.url(address)))
    }

    // MARK: The error half

    @Test func offlineErrorAgainstALanAddressReachesTheProbe() {
        #expect(LocalNetworkAccess.couldBeDenial(Self.offline, url: Self.url("http://10.0.0.5:8096")))
    }

    /// The same sentence about an address the permission has no say over is just an offline device.
    @Test func offlineErrorAgainstAPublicAddressDoesNot() {
        #expect(!LocalNetworkAccess.couldBeDenial(Self.offline, url: Self.url("https://jellyfin.example.com")))
    }

    @Test(arguments: [
        URLError.Code.timedOut,
        .cannotConnectToHost,
        .cannotFindHost,
        .networkConnectionLost,
        .secureConnectionFailed,
    ])
    func ordinaryTransportFailuresDoNot(_ code: URLError.Code) {
        #expect(!LocalNetworkAccess.couldBeDenial(URLError(code), url: Self.url("http://10.0.0.5:8096")))
    }

    /// The BSD-layer reading, arriving where it actually arrives: buried under the URL error.
    @Test func enetdownUnderneathAnotherErrorIsFound() {
        let buried = NSError(
            domain: NSURLErrorDomain,
            code: URLError.Code.cannotConnectToHost.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))]
        )
        #expect(LocalNetworkAccess.couldBeDenial(buried, url: Self.url("http://192.168.0.9:8096")))
    }

    @Test func aDifferentErrnoUnderneathIsNotADenial() {
        let refused = NSError(
            domain: NSURLErrorDomain,
            code: URLError.Code.cannotConnectToHost.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))]
        )
        #expect(!LocalNetworkAccess.couldBeDenial(refused, url: Self.url("http://192.168.0.9:8096")))
    }

    /// The walk is bounded, so a pathological chain cannot spin. Six deep is past the cap.
    @Test func theUnderlyingWalkStopsAtItsCap() {
        var error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))
        for _ in 0..<6 {
            error = NSError(
                domain: "Sodalite.Test",
                code: 1,
                userInfo: [NSUnderlyingErrorKey: error]
            )
        }
        #expect(!LocalNetworkAccess.couldBeDenial(error, url: Self.url("http://192.168.0.9:8096")))
    }

    // MARK: The connection reading

    @Test func onlyEnetdownNamesADenial() {
        #expect(LocalNetworkAccess.namesDenial(.posix(.ENETDOWN)))
        #expect(!LocalNetworkAccess.namesDenial(.posix(.ECONNREFUSED)))
        #expect(!LocalNetworkAccess.namesDenial(.posix(.ETIMEDOUT)))
        #expect(!LocalNetworkAccess.namesDenial(.posix(.EHOSTUNREACH)))
    }

    // MARK: What the app says about it

    @Test func theCaseCarriesTranslatableCopy() {
        let text = ErrorText.user(for: APIError.localNetworkDenied)
        #expect(!text.isEmpty)
        #expect(!text.contains("APIError"))
        #expect(!text.contains("Sodalite."))
    }

    // MARK: Where it ranks against the other verdicts

    /// A denial says this device would not have let ANY candidate through, so it describes the race
    /// better than a candidate's own reading of the address does. Without this it lost to the
    /// captive-portal branch and the login screen went back to blaming the server.
    @Test func denialOutranksEveryVerdictAboutTheAddress() {
        let verdicts: [Result<Int, APIError>?] = [
            .failure(.decodingError(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "")))),
            .failure(.localNetworkDenied),
            .failure(.timeout),
        ]
        if case .localNetworkDenied = DiscoveryProbeRace.aggregateError(verdicts) {} else {
            Issue.record("a denial describes the race better than any candidate's reading of the address")
        }
    }

    @Test func aRaceWithoutADenialIsUnchanged() {
        let verdicts: [Result<Int, APIError>?] = [.failure(.timeout), .failure(.serverUnreachable)]
        if case .timeout = DiscoveryProbeRace.aggregateError(verdicts) {} else {
            Issue.record("the cap is still our decision to stop waiting, not a verdict about the server")
        }
    }

    /// The log line is read in an issue thread, so it stays English and stays distinct from the
    /// other outcomes a reporter might paste beside it.
    @Test func theDiagnosticLineNamesTheDenial() {
        #expect(DiscoveryProbeRace.logLabel(for: .localNetworkDenied) == "local network denied")
    }

    // MARK: Which path reading may allow the accusation

    @Test func cellularOnlyNeverAllowsTheAccusation() {
        let cellular = NetworkPathSnapshot.Reading(isSatisfied: true, usesLocalInterface: false, hasLocalInterface: false)
        #expect(!LocalNetworkAccess.mayAccuse(reading: cellular))
    }

    @Test func aLocalInterfaceAllowsTheAccusation() {
        let wifi = NetworkPathSnapshot.Reading(isSatisfied: true, usesLocalInterface: false, hasLocalInterface: true)
        #expect(LocalNetworkAccess.mayAccuse(reading: wifi))
    }

    /// A missing reading is not evidence, so a real denial is never suppressed for want of one.
    @Test func noReadingFailsOpen() {
        #expect(LocalNetworkAccess.mayAccuse(reading: nil))
    }
}
