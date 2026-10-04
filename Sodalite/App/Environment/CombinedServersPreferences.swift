import Foundation

/// Per-profile switch for the combined Home and the servers the profile left out of it
/// (Sodalite#85). `scope` is `ProfileKey.storageScope`.
final class CombinedServersPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func isEnabled(scope: String) -> Bool { defaults.bool(forKey: "combineServers.\(scope)") }

    func setEnabled(_ enabled: Bool, scope: String) {
        defaults.set(enabled, forKey: "combineServers.\(scope)")
    }

    func excludedServerIDs(scope: String) -> Set<String> {
        Set(defaults.stringArray(forKey: "combineServersExcluded.\(scope)") ?? [])
    }

    func setExcluded(_ ids: Set<String>, scope: String) {
        defaults.set(ids.sorted(), forKey: "combineServersExcluded.\(scope)")
    }

    /// Device-local on purpose: participant order is device-local too.
    func liveTVServerID(scope: String) -> String? { defaults.string(forKey: "combineServersLiveTV.\(scope)") }

    func setLiveTVServerID(_ serverID: String, scope: String) {
        defaults.set(serverID, forKey: "combineServersLiveTV.\(scope)")
    }
}
