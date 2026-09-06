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
            probedURL: lanURL, answered: true, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true
        ) == .reachable)
    }

    /// Nothing may outrank a server that is demonstrably answering, including a path the monitor
    /// has not caught up with.
    @Test("an answer wins even against an unsatisfied path")
    func answerBeatsPath() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: true, hasAlternateSlot: false,
            pathIsSatisfied: false, isAttachedToALocalNetwork: false
        ) == .reachable)
    }

    // MARK: No network at all

    /// Matrix rows 8 and 9: airplane mode, and a Wi-Fi-only iPad with Wi-Fi off. Nothing about the
    /// server is knowable from here, so the verdict must not be about the server.
    @Test("no path means no network, whatever the address is")
    func unsatisfiedPath() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: false, isAttachedToALocalNetwork: false
        ) == .noNetwork)
        #expect(ServerReachability.classify(
            probedURL: publicURL, answered: false, hasAlternateSlot: true,
            pathIsSatisfied: false, isAttachedToALocalNetwork: false
        ) == .noNetwork)
    }

    /// An unknown path is a reason to stay vague, never a reason to accuse the device: the monitor's
    /// first callback has not landed yet, and "you are offline" would be a guess dressed as a fact.
    @Test("an unknown path never reads as offline")
    func unknownPathIsNotOffline() {
        #expect(ServerReachability.classify(
            probedURL: publicURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: nil, isAttachedToALocalNetwork: nil
        ) == .unreachable)
    }

    // MARK: The one case with advice attached

    /// Matrix rows 1 and 15: the reported configuration. A LAN address, no remote slot, and a device
    /// that is on some network but not that one.
    @Test("a LAN-only server with no remote slot is off-network")
    func lanOnlyOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: false
        ) == .offNetwork)
    }

    /// The over-claim this case used to make, and the one an Apple TV would have hit on every
    /// outage it can have: a device sitting ON a local network whose LAN server does not answer is
    /// not a device on the wrong network. Its server is off, or asleep, or on a different subnet.
    /// "Only reachable on your home network" is false there, and the address advice under it is
    /// worse than useless, since no second URL brings a powered-down server back.
    @Test("a device attached to a LAN is never told it is off the network")
    func attachedToALANIsNotOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true
        ) == .unreachable)
    }

    /// Matrix rows 5 and 6, foreign Wi-Fi and a phone hotspot. The address might legitimately exist
    /// on that LAN, so the app does not know, and the report's own matrix asks for the softer claim
    /// here. Attachment is what separates it from row 1, which is why the classifier reads it.
    @Test("a foreign network gets the softer claim, not the home-network one")
    func foreignWiFi() {
        #expect(ServerReachability.classify(
            probedURL: mdnsURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true
        ) == .unreachable)
    }

    /// An unknown attachment is a reason to stay vague for the same reason an unknown path is:
    /// `.offNetwork` is a claim about where the device is standing, and a claim needs a reading.
    @Test("unknown attachment never yields the claim")
    func unknownAttachment() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: nil, isAttachedToALocalNetwork: nil
        ) == .unreachable)
    }

    /// Matrix row 3: a server that already carries a remote address is not missing one. Telling its
    /// owner to add a remote address is a wrong instruction, so the case that carries that advice
    /// must not claim them.
    @Test("a dual-slot server is never told to add an address it has")
    func dualSlotIsNotOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: true,
            pathIsSatisfied: true, isAttachedToALocalNetwork: false
        ) == .unreachable)
    }

    /// A hostname that is internal by suffix is still an internal address, and `.local` is the one
    /// a pre-flight predicate could never have classified: it cannot be resolved without asking.
    @Test("an mDNS name counts as a LAN address")
    func mdnsIsInternal() {
        #expect(ServerReachability.classify(
            probedURL: mdnsURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: false
        ) == .offNetwork)
    }

    /// The trap `LocalNetworkAccess.isGoverned` exists to hold, and the reason the LAN test goes
    /// through it instead of through `ServerURLClassifier.isInternal`: loopback classifies as
    /// internal there, for its own purposes. A loopback server that stopped answering has nothing to
    /// do with which network the device is on, and no remote address would fix it.
    @Test("loopback is not an off-network server")
    func loopbackIsNotOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: loopbackURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: false
        ) == .unreachable)
    }

    // MARK: Everything the app cannot narrow

    /// Matrix row 12: a public hostname whose server is genuinely down. The app must keep the vague
    /// sentence here rather than invent a confident wrong one, because it does not know why.
    @Test("a public address that stopped answering stays unexplained")
    func publicHostDown() {
        #expect(ServerReachability.classify(
            probedURL: publicURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true
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

/// Sodalite#122, second round. The Local Network denial screen from Sodalite#92 claimed matrix row 1
/// on a device the report predicted it would stay silent on. Measured on an iPhone 17 Pro, Wi-Fi
/// off, 5G up, LAN-only server: the scoped probe reported a denial and the app told its owner to
/// switch on a permission that was already on.
///
/// The permission governs a LAN this device is attached to. With no Wi-Fi and no Ethernet there is
/// no such LAN, so every reason the probe can report is answering a different question, and the
/// accusation is incoherent before it is wrong. That is a coherence check on a claim about the
/// DEVICE, not a prediction about reachability, which is why it can only ever withdraw a claim.
@Suite("Local network denial preconditions")
struct LocalNetworkAttachmentTests {
    private func reading(satisfied: Bool, uses: Bool, has: Bool) -> NetworkPathSnapshot.Reading {
        NetworkPathSnapshot.Reading(
            isSatisfied: satisfied, usesLocalInterface: uses, hasLocalInterface: has
        )
    }

    @Test("cellular alone is not a local network")
    func cellularOnly() {
        #expect(reading(satisfied: true, uses: false, has: false).isAttachedToALocalNetwork == false)
    }

    @Test("Wi-Fi in use is a local network")
    func wifiInUse() {
        #expect(reading(satisfied: true, uses: true, has: true).isAttachedToALocalNetwork)
    }

    /// The generous half of the OR, and the reason both readings are taken. A phone on Wi-Fi that
    /// the system currently prefers to route around is still attached to a LAN, and a denial there
    /// is real. Suppressing it would put back the wrong sentence #92 exists to remove.
    @Test("Wi-Fi present but unused still counts")
    func wifiPresentUnused() {
        #expect(reading(satisfied: true, uses: false, has: true).isAttachedToALocalNetwork)
    }

    /// Airplane mode: no path and no interfaces. Not a denial either, and `.noNetwork` is what says
    /// so instead.
    @Test("no path at all is not a denial")
    func noPath() {
        #expect(reading(satisfied: false, uses: false, has: false).isAttachedToALocalNetwork == false)
    }
}

/// Sodalite#122, follow-up round. The verdict was measured once for the whole app and then read by
/// exactly one screen, so the library grid went on rendering the generic "check the connection"
/// line that #122 exists to delete. The rule is shared now, and it is pinned here rather than left
/// to two view bodies to agree with each other.
@Suite("What a screen shows instead of content")
struct ServerReachabilityBlockingStateTests {
    /// The fast half: the probe has a verdict long before any fan-out proves the same thing one
    /// thirty second timeout at a time, and it is the verdict that picks the sentence.
    @Test("a failed verdict speaks for itself")
    func failureSpeaks() {
        for verdict in [ServerReachability.noNetwork, .offNetwork, .unreachable] {
            #expect(verdict.blockingState(hasContent: false, loadFailedEntirely: false) == verdict)
        }
    }

    /// Content that arrived anyway outranks the probe, which asked one endpoint. This is what keeps
    /// a dual-slot server on a working external route off the screen, and what stops a cached grid
    /// from being replaced by an apology for something the user can already see.
    @Test("anything painted outranks every verdict")
    func contentOutranksTheVerdict() {
        for verdict in [ServerReachability.noNetwork, .offNetwork, .unreachable, .reachable, .unknown] {
            #expect(verdict.blockingState(hasContent: true, loadFailedEntirely: true) == nil)
        }
    }

    /// The still-loading first seconds. Neither source has anything to say, and a screen that
    /// flashed an error here would be wrong about a server that is about to answer.
    @Test("no verdict and no failure keeps loading")
    func silenceKeepsLoading() {
        #expect(ServerReachability.unknown.blockingState(hasContent: false, loadFailedEntirely: false) == nil)
        #expect(ServerReachability.reachable.blockingState(hasContent: false, loadFailedEntirely: false) == nil)
    }

    /// The slow half, still needed: a load can drain empty against a server the probe reached, and
    /// then the screen may say THAT it failed but must not claim to know why. `.offNetwork` carries
    /// advice about addresses and would be a wrong instruction here.
    @Test("a drained fan-out claims nothing about why")
    func drainedFanOutStaysVague() {
        #expect(ServerReachability.reachable.blockingState(hasContent: false, loadFailedEntirely: true) == .unreachable)
        #expect(ServerReachability.unknown.blockingState(hasContent: false, loadFailedEntirely: true) == .unreachable)
    }
}

/// Sodalite#126. The verdict was consumed at first load and never again, so a session that left the
/// network mid-browse kept browsing as though nothing had changed and the first hard stop was Play.
///
/// The pair pinned here is the fix. `blockingState` speaks where nothing painted; `bannerState`
/// speaks where something did. Neither was allowed to grow into the other's case: replacing painted
/// rows with an error screen throws away a feed the reader can still use, undoes the shelf painted
/// from disk in Sodalite#117, and would put a wall in front of a device holding downloads once #81
/// lands.
@Suite("Full screen and status strip divide the verdict")
struct ServerReachabilityBannerStateTests {
    private let allVerdicts: [ServerReachability] = [.unknown, .reachable, .noNetwork, .offNetwork, .unreachable]

    /// The invariant that makes the pair a pair: a failing verdict is said exactly once, whether or
    /// not the tab has anything on screen. Two voices would stack the strip under a screen saying
    /// the same thing; none would be the bug this issue is about.
    @Test("a failing verdict is said exactly once")
    func saidExactlyOnce() {
        for verdict in allVerdicts where verdict.isFailure {
            for hasContent in [true, false] {
                let full = verdict.blockingState(hasContent: hasContent, loadFailedEntirely: false)
                let strip = verdict.bannerState(fullScreenIsShowing: full != nil)
                #expect((full == nil) != (strip == nil))
            }
        }
    }

    /// Silence stays silence. A tab whose load simply failed against a server the probe reached gets
    /// its own screen from `blockingState`; the strip has nothing measured to report and must not
    /// invent a network story for it.
    @Test("no verdict means no strip, whatever the screen is doing")
    func noVerdictNoStrip() {
        for showing in [true, false] {
            #expect(ServerReachability.unknown.bannerState(fullScreenIsShowing: showing) == nil)
            #expect(ServerReachability.reachable.bannerState(fullScreenIsShowing: showing) == nil)
        }
    }

    /// The strip carries the verdict itself, so the sentence it draws is the same one the full
    /// screen would have drawn. One fact, one wording.
    @Test("the strip says what the screen would have said")
    func stripCarriesTheVerdict() {
        for verdict in allVerdicts where verdict.isFailure {
            #expect(verdict.bannerState(fullScreenIsShowing: false) == verdict)
        }
    }
}
