import Foundation
import Network

/// Debounced NWPathMonitor wrapper. The first callback after start() reports
/// the current path, not a change, and is latched away so launch does not
/// double-resolve. 1 s debounce collapses a WiFi handoff burst into one
/// resolve.
///
/// The change callback is an iOS concern (route re-resolution on a handoff);
/// the path *status* is not, which is why start() is unconditional. See
/// `NetworkPathSnapshot`.
@MainActor
final class NetworkPathObserver {
    var onPathChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var debounceTask: Task<Void, Never>?
    private var didSeeInitialPath = false
    private var isStarted = false

    func start() {
        // AppRouter's .task re-fires on modal dismissal; a second
        // NWPathMonitor.start() asserts in libnetwork, so latch.
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { path in
            // Recorded off the monitor queue, before the MainActor hop: the route resolve reads
            // this synchronously and must not race a hop that has not landed yet.
            NetworkPathSnapshot.shared.record(NetworkPathSnapshot.Reading(path))
            Task { @MainActor [weak self] in
                self?.pathDidUpdate()
            }
        }
        monitor.start(queue: DispatchQueue(label: "de.superuser404.Sodalite.pathMonitor"))
    }

    func stop() {
        monitor.cancel()
        debounceTask?.cancel()
    }

    private func pathDidUpdate() {
        guard didSeeInitialPath else {
            didSeeInitialPath = true
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onPathChange?()
        }
    }
}

/// The last path status the monitor reported, mirrored where the network layer can read it
/// synchronously (Sodalite#122).
///
/// The route resolve needs it to tell "this address does not answer" from "this device has no
/// network at all". Those are the same probe failure and two completely different sentences, and
/// only the first one has advice attached: offering to edit a server URL to someone in airplane
/// mode is noise.
///
/// A snapshot rather than a question asked on demand, because a freshly started NWPathMonitor takes
/// a callback turn to report anything and the resolve has finished by then. `nil` until that first
/// callback lands, and a nil is deliberately not "offline": an unknown path makes the verdict stay
/// vague, it never lets it accuse the device.
nonisolated final class NetworkPathSnapshot: @unchecked Sendable {
    static let shared = NetworkPathSnapshot()

    struct Reading: Sendable, Equatable {
        let isSatisfied: Bool
        /// Is the path actually running over Wi-Fi or Ethernet right now?
        let usesLocalInterface: Bool
        /// Is such an interface in the picture at all, used or not? Broader than the above on
        /// purpose: a device on Wi-Fi that the system currently prefers to route around is still a
        /// device attached to a local network.
        let hasLocalInterface: Bool

        /// True where a local network exists for a permission to govern. Both readings are taken
        /// because only the pair says which one iOS actually moves when Wi-Fi goes off, and the
        /// generous OR is the safe side: it can only ever fail to suppress a denial, never suppress
        /// a real one.
        var isAttachedToALocalNetwork: Bool { usesLocalInterface || hasLocalInterface }
    }

    private let lock = NSLock()
    private var reading: Reading?

    var current: Reading? {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    var isSatisfied: Bool? { current?.isSatisfied }

    func record(_ reading: Reading) {
        lock.lock()
        self.reading = reading
        lock.unlock()
    }
}

extension NetworkPathSnapshot.Reading {
    nonisolated init(_ path: NWPath) {
        let localTypes: Set<NWInterface.InterfaceType> = [.wifi, .wiredEthernet]
        self.init(
            isSatisfied: path.status == .satisfied,
            usesLocalInterface: localTypes.contains(where: path.usesInterfaceType),
            hasLocalInterface: path.availableInterfaces.contains { localTypes.contains($0.type) }
        )
    }
}
