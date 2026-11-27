#if os(tvOS)
import Foundation
import GameController
import Observation

/// Where the thumb is on the Siri Remote's touch surface, for `focusTilt` (Sodalite#259).
///
/// The pad stays in its default relative mode (a window centred on first contact), the same model the
/// system parallax uses. It listens through the GAMEPAD's `valueChangedHandler`, never the dpad's:
/// `SiriRemoteSurfaceTracker` owns `dpad.valueChangedHandler` while a player is up and sets it to nil
/// when the player closes, so sharing that slot would have each one silently unhook the other.
@Observable
@MainActor
final class RemoteTouchSource {

    static let shared = RemoteTouchSource()

    /// How long the pad has to sit at exactly 0,0 before that counts as a lifted thumb. GameController
    /// deadzones each axis to exactly 0, so a thumb sliding through the centre reads 0,0 for a sample
    /// or two, and taken at face value that snapped the card flat mid-gesture and started a new touch.
    static let liftDelay: Duration = .milliseconds(100)

    /// Remotes with a touch surface. A game controller's d-pad is digital and would flip the card by
    /// the full angle on every press; the Control Center remote reports no position at all (measured
    /// in `SiriRemoteSurfaceTracker`).
    private static let touchRemotes: Set<String> = [
        GCProductCategorySiriRemote1stGen,
        GCProductCategorySiriRemote2ndGen,
        GCProductCategoryCoalescedRemote,
    ]

    private(set) var reading = RemoteTouchReading()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var attached: [ObjectIdentifier: GCController] = [:]
    /// Focused cards that want readings. Nothing is written while it is zero, so the player, music and
    /// the keyboard do not pay for a stream nobody draws.
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var pendingLift: Task<Void, Never>?

    init() {}

    /// A focused card wants readings. The first one also takes the pad's current position, so its
    /// origin is where the thumb really is and not a reading from before anyone listened.
    func acquire() {
        start()
        demand += 1
        guard demand == 1 else { return }
        let live = attached.values.lazy
            .compactMap(\.microGamepad)
            .first { $0.dpad.xAxis.value != 0 || $0.dpad.yAxis.value != 0 }
        cancelLift()
        publish(x: Double(live?.dpad.xAxis.value ?? 0), y: Double(live?.dpad.yAxis.value ?? 0))
    }

    func release() {
        demand = max(demand - 1, 0)
        if demand == 0 { cancelLift() }
    }

    /// One pad sample. Internal for the tests.
    func ingest(x: Double, y: Double) {
        guard demand > 0 else { return }
        guard x == 0, y == 0 else {
            cancelLift()
            publish(x: x, y: y)
            return
        }
        guard reading.isTouching, pendingLift == nil else { return }
        pendingLift = Task { [weak self] in
            try? await Task.sleep(for: Self.liftDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingLift = nil
            self.publish(x: 0, y: 0)
        }
    }

    private func cancelLift() {
        pendingLift?.cancel()
        pendingLift = nil
    }

    private func publish(x: Double, y: Double) {
        guard x != reading.x || y != reading.y else { return }
        let startsTouch = !reading.isTouching && (x != 0 || y != 0)
        reading = RemoteTouchReading(x: x, y: y, touch: reading.touch + (startsTouch ? 1 : 0))
    }

    // MARK: - Controller wiring

    private func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            })
        }
        refreshControllers()
    }

    private func refreshControllers() {
        let connected = GCController.controllers()
        let live = Set(connected.map(ObjectIdentifier.init))
        for id in attached.keys where !live.contains(id) {
            attached.removeValue(forKey: id)?.microGamepad?.valueChangedHandler = nil
        }
        for controller in connected { attach(controller) }
        let pads = attached.values.map(\.productCategory).joined(separator: ", ")
        LogTap.shared.note("[Tilt] listening on \(attached.count) remote(s)\(pads.isEmpty ? "" : ": \(pads)")")
    }

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard attached[id] == nil,
              Self.touchRemotes.contains(controller.productCategory),
              let pad = controller.microGamepad else { return }
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            let x = Double(gamepad.dpad.xAxis.value)
            let y = Double(gamepad.dpad.yAxis.value)
            MainActor.assumeIsolated { self?.ingest(x: x, y: y) }
        }
        attached[id] = controller
    }
}
#endif
