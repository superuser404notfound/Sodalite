import Foundation
import Testing
@testable import Sodalite

/// Sodalite#122. The matrix the verdict has to get right, pinned here rather than on a device.
///
/// The correctness bar is asymmetric and worth stating, because it is what shaped the design. A
/// verdict that is too permissive costs a wrong sentence. A verdict that is too restrictive would
/// break a working setup with no diagnosable symptom, which is far worse, and it is exactly what a
/// "cellular implies block LAN addresses" rule would do to a Tailscale or WireGuard user.
///
/// This classifier cannot make that mistake, and the reason is structural rather than careful: it
/// never predicts, it only reports a probe that already ran against the real address. A tunnel
/// carrying RFC1918 on cellular simply answers. That is why `answered` is the first thing read and
/// nothing else can override it.
@Suite("Server reachability verdict")
struct ServerReachabilityTests {
    private let lanURL = URL(string: "http://192.168.1.50:8096")!
    private let publicURL = URL(string: "https://jellyfin.example.com")!
    private let mdnsURL = URL(string: "http://jellyfin.local:8096")!
    private let loopbackURL = URL(string: "http://127.0.0.1:8096")!

    // MARK: An answer outranks everything

    /// Matrix row 4: cellular, no Wi-Fi, LAN-only address, VPN carrying it. The setup a heuristic
    /// would have refused, and the reason this is a measurement.
    @Test("a LAN address that answers is reachable, whatever the path looks like")
    func tunnelledLANAnswers() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: true, hasAlternateSlot: false, pathIsSatisfied: true
        ) == .reachable)
    }

    /// Nothing may outrank a server that is demonstrably answering, including a path the monitor
    /// has not caught up with.
    @Test("an answer wins even against an unsatisfied path")
    func answerBeatsPath() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: true, hasAlternateSlot: false, pathIsSatisfied: false
        ) == .reachable)
    }

    // MARK: No network at all

    /// Matrix rows 8 and 9: airplane mode, and a Wi-Fi-only iPad with Wi-Fi off. Nothing about the
    /// server is knowable from here, so the verdict must not be about the server.
    @Test("no path means no network, whatever the address is")
    func unsatisfiedPath() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false, pathIsSatisfied: false
        ) == .noNetwork)
        #expect(ServerReachability.classify(
            probedURL: publicURL, answered: false, hasAlternateSlot: true, pathIsSatisfied: false
        ) == .noNetwork)
    }

    /// An unknown path is a reason to stay vague, never a reason to accuse the device: the monitor's
    /// first callback has not landed yet, and "you are offline" would be a guess dressed as a fact.
    @Test("an unknown path never reads as offline")
    func unknownPathIsNotOffline() {
        #expect(ServerReachability.classify(
            probedURL: publicURL, answered: false, hasAlternateSlot: false, pathIsSatisfied: nil
        ) == .unreachable)
    }

    // MARK: The one case with advice attached

    /// Matrix rows 1 and 15: the reported configuration. A LAN address, no remote slot, and a device
    /// that is on some network but not that one.
    @Test("a LAN-only server with no remote slot is off-network")
    func lanOnlyOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false, pathIsSatisfied: true
        ) == .offNetwork)
    }

    /// Matrix row 3: a server that already carries a remote address is not missing one. Telling its
    /// owner to add a remote address is a wrong instruction, so the case that carries that advice
    /// must not claim them.
    @Test("a dual-slot server is never told to add an address it has")
    func dualSlotIsNotOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: true, pathIsSatisfied: true
        ) == .unreachable)
    }

    /// A hostname that is internal by suffix is still an internal address, and `.local` is the one
    /// a pre-flight predicate could never have classified: it cannot be resolved without asking.
    @Test("an mDNS name counts as a LAN address")
    func mdnsIsInternal() {
        #expect(ServerReachability.classify(
            probedURL: mdnsURL, answered: false, hasAlternateSlot: false, pathIsSatisfied: true
        ) == .offNetwork)
    }

    /// The trap `LocalNetworkAccess.isGoverned` exists to hold, and the reason the LAN test goes
    /// through it instead of through `ServerURLClassifier.isInternal`: loopback classifies as
    /// internal there, for its own purposes. A loopback server that stopped answering has nothing to
    /// do with which network the device is on, and no remote address would fix it.
    @Test("loopback is not an off-network server")
    func loopbackIsNotOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: loopbackURL, answered: false, hasAlternateSlot: false, pathIsSatisfied: true
        ) == .unreachable)
    }

    // MARK: Everything the app cannot narrow

    /// Matrix row 12: a public hostname whose server is genuinely down. The app must keep the vague
    /// sentence here rather than invent a confident wrong one, because it does not know why.
    @Test("a public address that stopped answering stays unexplained")
    func publicHostDown() {
        #expect(ServerReachability.classify(
            probedURL: publicURL, answered: false, hasAlternateSlot: false, pathIsSatisfied: true
        ) == .unreachable)
    }

    @Test("only the failures count as failures")
    func isFailure() {
        #expect(ServerReachability.unknown.isFailure == false)
        #expect(ServerReachability.reachable.isFailure == false)
        #expect(ServerReachability.noNetwork.isFailure)
        #expect(ServerReachability.offNetwork.isFailure)
        #expect(ServerReachability.unreachable.isFailure)
    }
}
