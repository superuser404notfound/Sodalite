import Foundation

/// When each server was last made the active one on THIS device. Device knowledge, so it never
/// syncs. Orders the secondary sessions of a combined Home (Sodalite#85).
final class ServerActivationStore {
    private static let key = "serverLastActivatedAt"
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func all() -> [String: Date] {
        raw().mapValues { Date(timeIntervalSince1970: $0) }
    }

    func lastActivated(serverID: String) -> Date? { all()[serverID] }

    func stamp(serverID: String) {
        var stamps = raw()
        stamps[serverID] = now().timeIntervalSince1970
        defaults.set(stamps, forKey: Self.key)
    }

    func forget(serverID: String) {
        var stamps = raw()
        stamps[serverID] = nil
        defaults.set(stamps, forKey: Self.key)
    }

    private func raw() -> [String: Double] {
        defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
    }
}
