#if os(tvOS)
import Foundation
import GameController

/// Sodalite#115: reads WHERE on the 1st-generation Siri Remote's glass surface the user clicked, so
/// `PlayerHostController` can tell an edge click from a centre click. UIKit cannot answer that (see
/// `SiriRemoteEdgeClick`), GameController can.
///
/// The position is latched the moment the button goes down, not read when the press is evaluated. A
/// `UITapGestureRecognizer` on `.select` fires on release, and by then the thumb has left the glass and
/// the dpad has recentred to 0,0, so a late reading would report every click as a centre click.
///
/// Only the 1st-generation remote is tracked. The 2021 remote's outer ring already delivers real
/// `.leftArrow`/`.rightArrow` presses, which the host handles on their own path; treating its clickpad
/// as an edge surface as well would give one press two meanings.
@MainActor
final class SiriRemoteSurfaceTracker {

    /// How long a latched click stays answerable. It has to clear the host's own 0.35 s hold threshold:
    /// the `.select` tap recognizer requires the hold recognizer to FAIL first, so the press this latch
    /// answers can arrive a third of a second after the button went down. A tighter window would drop
    /// exactly the slower clicks. It matters at all because coalescing is off (see Info.plist), so a
    /// physical and a Control Center remote can be live at once and one can latch while the other clicks.
    private static let latchLifetime: TimeInterval = 1.0

    /// Remotes whose whole surface sits on one button, where a click carries no direction of its own.
    /// The 2021 remote is deliberately absent: its outer ring already delivers real `.leftArrow` and
    /// `.rightArrow` presses, which never reach the select handler, and reading its clickpad as an edge
    /// surface as well would give a single press two meanings in the band where the two overlap.
    /// The Control Center remote was in this set for one build, on the argument that its virtual surface
    /// has the same shape. Measured on the living room Apple TV: eleven clicks in a row reported exactly
    /// x=0.00 y=0.00, so it reports no position at all and can never produce an edge click. It stays out.
    private static let trackedCategories: Set<String> = [
        GCProductCategorySiriRemote1stGen,
    ]

    private var latchedDirection: Int?
    private var latchedAt: Date?
    /// The last non-centre reading and when it arrived. Diagnostic only, never decides anything: on the
    /// 2021 remote a click was measured reading x=0.00 soon after the pad had reported x=0.71, so a
    /// reporter's log has to be able to show whether the click read a live touch or an already recentred
    /// pad. Deciding FROM it would turn a deliberate centre click into a seek, which is the wrong way to
    /// be wrong.
    private var lastLivePosition: (x: Float, y: Float, at: Date)?
    private var observers: [NSObjectProtocol] = []
    private var attachedControllers: [ObjectIdentifier: GCController] = [:]

    /// Start watching for 1st-generation remotes. Idempotent per instance.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Both notifications re-scan rather than read `note.object`: a Notification is not Sendable, so
        // reaching into it from the main-actor hop is a data race the compiler rightly refuses. The
        // controller list is the same answer and costs nothing at this frequency.
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            })
        }
        note("tracker started")
        refreshControllers()
    }

    /// Drop every handler and observer. Called from the host's teardown so a gone player stops holding
    /// the remote's callbacks.
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for controller in attachedControllers.values {
            controller.microGamepad?.buttonA.pressedChangedHandler = nil
            controller.microGamepad?.dpad.valueChangedHandler = nil
        }
        attachedControllers.removeAll()
        lastLivePosition = nil
        latchedDirection = nil
        latchedAt = nil
    }

    /// The direction of the most recent edge click, if there was one and it is still fresh. Consuming
    /// clears it, so one click can only answer one press.
    func consumeEdgeDirection() -> Int? {
        defer { latchedDirection = nil; latchedAt = nil }
        guard let direction = latchedDirection, let at = latchedAt else { return nil }
        guard Date().timeIntervalSince(at) <= Self.latchLifetime else { return nil }
        return direction
    }

    // MARK: - Controller wiring

    /// Attach to every connected 1st-generation remote, drop the ones that went away.
    private func refreshControllers() {
        let connected = GCController.controllers()
        let live = Set(connected.map(ObjectIdentifier.init))
        for id in attachedControllers.keys where !live.contains(id) {
            let pad = attachedControllers.removeValue(forKey: id)?.microGamepad
            pad?.buttonA.pressedChangedHandler = nil
            pad?.dpad.valueChangedHandler = nil
        }
        for controller in connected { attach(controller) }
        logInventory(connected)
    }

    /// What GameController actually reports, logged on every scan. Without it the ONLY evidence this
    /// class produces is a line it writes after attaching, so a silent log cannot tell "this remote is
    /// correctly ignored" from "the tracker never ran". Both readings matter and they look identical.
    private func logInventory(_ connected: [GCController]) {
        guard !connected.isEmpty else {
            note("scan: GameController reports no controllers at all")
            return
        }
        let inventory = connected.map { controller in
            let category = controller.productCategory
            let pad = controller.microGamepad == nil ? "no microGamepad" : "microGamepad"
            let taken = attachedControllers[ObjectIdentifier(controller)] != nil ? "TRACKED" : "ignored"
            return "\(category) [\(pad), \(taken)]"
        }.joined(separator: ", ")
        note("scan: \(connected.count) controller(s): \(inventory)")
    }

    private func attach(_ controller: GCController) {
        guard attachedControllers[ObjectIdentifier(controller)] == nil,
              Self.trackedCategories.contains(controller.productCategory),
              let pad = controller.microGamepad else { return }
        // Raw touchpad position instead of a sliding window centred on first contact: the window is the
        // right model for steering, the wrong one for "which part of the glass is under the thumb".
        pad.reportsAbsoluteDpadValues = true
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            guard x != 0 || y != 0 else { return }
            MainActor.assumeIsolated { self?.lastLivePosition = (x, y, Date()) }
        }
        // Fires on button DOWN, which is what makes the reading trustworthy: the `.select` recognizer
        // this pairs with fires on release. `[weak pad]` because the handler is stored ON the pad.
        pad.buttonA.pressedChangedHandler = { [weak self, weak pad] _, _, pressed in
            guard pressed, let pad else { return }
            let x = pad.dpad.xAxis.value
            let y = pad.dpad.yAxis.value
            MainActor.assumeIsolated { self?.latch(x: x, y: y) }
        }
        attachedControllers[ObjectIdentifier(controller)] = controller
    }

    /// Every line this class produces goes through here, so the prefix is written once.
    private func note(_ line: String) {
        LogTap.shared.note("[EdgeClick] \(line)")
    }

    private func latch(x: Float, y: Float) {
        let direction = SiriRemoteEdgeClick.direction(x: x, y: y)
        latchedDirection = direction
        latchedAt = direction == nil ? nil : Date()
        // The threshold is a guess (no 1st-generation remote on this side), so every reading is logged
        // against it. Settings > Diagnostic Log is reachable on an App Store build, which makes a
        // reporter's screenshot the only way this number gets calibrated from real thumbs.
        let live: String
        if let last = lastLivePosition {
            live = String(format: " (last live x=%.2f y=%.2f, %.0f ms ago)",
                          last.x, last.y, Date().timeIntervalSince(last.at) * 1000)
        } else {
            live = " (pad never reported a position)"
        }
        note(String(
            format: "surface click x=%.2f y=%.2f threshold=%.2f -> %@%@",
            x, y, SiriRemoteEdgeClick.edgeThreshold,
            direction.map { $0 < 0 ? "back" : "forward" } ?? "centre", live))
    }
}
#endif
