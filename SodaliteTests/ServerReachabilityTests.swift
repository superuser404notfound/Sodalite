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

/// Sodalite#126, device round. The strip and the player were right and never appeared, because
/// nothing re-measured the verdict: every trigger the app had was an event about the DEVICE, a path
/// change, a foreground, a server switch. On a phone the reported case is a path change, so the gap
/// stayed hidden. On an Apple TV, which never leaves its network, no device event exists for the
/// only outage it can have, and the app believed its launch measurement for the rest of the session.
///
/// Measured on Wohnzimmer, tvOS 26.6, 2026-09-06: stopping the server while the app ran changed
/// nothing on screen; only relaunching showed the right one.
@Suite("Re-measuring a verdict that went stale")
struct ReachabilityRecheckTests {
    /// The early checks are for a server that was just restarted and is seconds from answering; the
    /// ceiling is for one that is off for the evening and must not be asked all night.
    @Test("the schedule backs off and then holds")
    func schedule() {
        #expect(ReachabilityRecheck.delay(forAttempt: 0) == .seconds(5))
        #expect(ReachabilityRecheck.delay(forAttempt: 1) == .seconds(10))
        #expect(ReachabilityRecheck.delay(forAttempt: 2) == .seconds(20))
        #expect(ReachabilityRecheck.delay(forAttempt: 3) == ReachabilityRecheck.ceiling)
    }

    /// Whatever the attempt count reaches over a night, the gap is bounded. An unbounded backoff
    /// would eventually mean the app has stopped asking without ever saying so.
    @Test("no attempt is ever asked to wait longer than the ceiling")
    func bounded() {
        for attempt in 0...10_000 {
            #expect(ReachabilityRecheck.delay(forAttempt: attempt) <= ReachabilityRecheck.ceiling)
        }
    }

    /// Monotonic, so a later check never comes sooner than an earlier one. A schedule that dipped
    /// would be a schedule that got busier the longer the server stayed down.
    @Test("the schedule never gets shorter")
    func monotonic() {
        for attempt in 1...20 {
            #expect(ReachabilityRecheck.delay(forAttempt: attempt) >= ReachabilityRecheck.delay(forAttempt: attempt - 1))
        }
    }

    /// A negative attempt is not a real input, but a schedule indexed by a counter should not trap
    /// on one either.
    @Test("a nonsense attempt still yields the first delay")
    func negativeAttempt() {
        #expect(ReachabilityRecheck.delay(forAttempt: -1) == .seconds(5))
    }

    /// The cooldown answers a different question from the schedule: not "how long until we ask
    /// again" but "how many of these failures are one piece of news". A failing session produces
    /// them by the dozen, and every one of them arrives at the same funnel.
    @Test("the failure cooldown is shorter than the steady interval and longer than a burst")
    func cooldown() {
        #expect(ReachabilityRecheck.cooldown > .seconds(2))
        #expect(ReachabilityRecheck.cooldown <= ReachabilityRecheck.ceiling)
    }
}

/// Sodalite#126, third device round, and the one finding a log gave up that no amount of reading the
/// code would have. Measured on 2026-09-06, iPhone, Jellyfin 10.11.11:
///
///     17:36:39.380  jelly-arrstack is unreachable
///     17:36:39.381  recheck watch armed
///     17:36:44.399  recheck attempt 1 after 5.0 seconds
///     17:36:51.116  jelly-arrstack is reachable
///     17:36:51.227  GET /Users/.../Views -> 503: <title>Jellyfin Startup</title>
///     17:36:54.743  recheck watch stopped
///
/// A Jellyfin that is still booting answers every request with 503 and its own startup page for the
/// better part of a minute. The probe's rule was "any HTTP response proves the host answers", which
/// is right for choosing between two addresses and wrong for deciding a session can run: the app
/// called it reachable, cleared the error screen, reloaded everything into 503s, painted the screen
/// straight back, and stopped watching because the verdict said all was well. The interface flashed
/// once and then waited for a human to press Try Again.
@Suite("What counts as the server answering")
struct ServerProbeAnswerTests {
    /// The case that was measured. 503 is the server saying it cannot serve, and Jellyfin says it
    /// for the whole of its startup.
    @Test("a server that is still booting is not answering")
    func bootingIsNotAnswering() {
        #expect(ServerProbe.answers(statusCode: 503) == false)
    }

    /// The whole family, since a reverse proxy in front of a restarting origin says 502 and 504
    /// where the origin itself would say 503.
    @Test("no 5xx is an answer")
    func noServerErrorIsAnAnswer() {
        for code in 500...599 {
            #expect(ServerProbe.answers(statusCode: code) == false)
        }
    }

    /// The half of the old rule that was right, and the reason the fix is a narrowing rather than a
    /// replacement: these come from a server that is up and merely disagreeing, and on some setups
    /// the status endpoint is behind auth. Calling them unreachable would break a working session,
    /// which is the more serious failure.
    @Test("a server that is up and disagreeing is still answering")
    func disagreementIsStillAnAnswer() {
        for code in [200, 204, 301, 302, 400, 401, 403, 404, 429] {
            #expect(ServerProbe.answers(statusCode: code))
        }
    }
}

/// Sodalite#126, fourth device round. Pinned because the obvious tidy-up here reintroduces the bug:
/// `System/Info/Public` reads like the natural thing for a server probe to ask, and it is what
/// discovery asks, and it is precisely the endpoint that cannot answer this question.
///
/// Measured on 2026-09-06 from a log, Jellyfin 10.11.11 mid-boot, one second apart:
///
///     GET /Users/.../Views  -> 503 Jellyfin Startup
///     GET /Users/Public     -> 503 Jellyfin Startup
///     probe System/Info/Public -> answered, verdict published as reachable
@Suite("Which endpoint says a session can run")
struct ServerProbeEndpointTests {
    /// The startup page covers the API and the login endpoint, and lets the identity endpoint
    /// through. Only an endpoint on the covered side can tell ready from listening.
    @Test("readiness is asked of an endpoint the startup page covers")
    func readinessPathIsBehindTheStartupGate() {
        #expect(ServerProbe.jellyfinReadinessPath == "Users/Public")
        #expect(ServerProbe.jellyfinReadinessPath != "System/Info/Public")
    }
}

/// The watch's own noise budget. `LogTap` holds 300 lines, and an outage that lasts an evening is
/// exactly when someone opens the diagnostic log, so a heartbeat every thirty seconds would flush
/// out the lines that explain what happened.
@Suite("The recheck watch stays quiet once it settles")
struct ReachabilityRecheckNoiseTests {
    @Test("the loud attempts are the ones that are still backing off")
    func loudAttemptsAreTheBackingOffOnes() {
        for attempt in 0..<ReachabilityRecheck.attemptsBeforeCeiling {
            #expect(ReachabilityRecheck.delay(forAttempt: attempt) < ReachabilityRecheck.ceiling)
        }
        #expect(ReachabilityRecheck.delay(forAttempt: ReachabilityRecheck.attemptsBeforeCeiling) == ReachabilityRecheck.ceiling)
    }

    /// A handful of lines per outage, not a heartbeat. The number is small enough that several
    /// outages fit in the buffer beside everything else worth reading.
    @Test("an outage costs a handful of lines, however long it lasts")
    func boundedNoise() {
        #expect(ReachabilityRecheck.attemptsBeforeCeiling <= 5)
    }
}
