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
}
