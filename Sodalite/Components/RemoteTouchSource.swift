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

    private(set) var reading = RemoteTouchReading()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var attached: [ObjectIdentifier: GCController] = [:]

    private init() {}

    /// Begins listening. Called by the first card that takes focus; idempotent.
    func start() {
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
        guard attached[id] == nil, let pad = controller.microGamepad else { return }
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            let x = Double(gamepad.dpad.xAxis.value)
            let y = Double(gamepad.dpad.yAxis.value)
            MainActor.assumeIsolated { self?.update(x: x, y: y) }
        }
        attached[id] = controller
    }

    private func update(x: Double, y: Double) {
        guard x != reading.x || y != reading.y else { return }
        // A new contact starts a new touch, so a card's origin from the last one stops counting.
        let touch = reading.isTouching || (x == 0 && y == 0) ? reading.touch : reading.touch + 1
        reading = RemoteTouchReading(x: x, y: y, touch: touch)
    }
}
#endif
