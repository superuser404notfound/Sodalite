import Foundation

/// The local subnets each server has answered from, so a Wi-Fi it never answered on can be named as
/// a foreign one instead of as a server that is down.
///
/// Stored per device in plain `UserDefaults`, not per profile and not synced: which networks this
/// box or phone has reached a server from is a fact about the device, and another device's homes
/// say nothing about it. Bounded so a phone that travels does not grow the list without end.
nonisolated enum ServerHomeNetworks {
    private static let keyPrefix = "serverHomeSubnets."
    private static let limit = 8

    static func known(serverID: String, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: keyPrefix + serverID) ?? [])
    }

    static func record(_ subnets: [LocalSubnet], serverID: String, defaults: UserDefaults = .standard) {
        guard !subnets.isEmpty else { return }
        var list = defaults.stringArray(forKey: keyPrefix + serverID) ?? []
        for subnet in subnets.map(\.description) {
            list.removeAll { $0 == subnet }
            list.insert(subnet, at: 0)
        }
        defaults.set(Array(list.prefix(limit)), forKey: keyPrefix + serverID)
    }

    /// Whether the Wi-Fi the device is on now is not one the server lives on.
    ///
    /// With history, a network the server never answered from is foreign. Without any (a fresh
    /// install, or a server only ever reached over a tunnel), only an address that cannot be on
    /// any attached subnet counts, which keeps a home whose server is merely off, or sits one
    /// routed VLAN away, from being told it is somewhere else. No readable subnet answers false:
    /// the claim is about where the device stands, and a claim needs a reading.
    static func isForeign(current: [LocalSubnet], known: Set<String>, serverHost: String) -> Bool {
        guard !current.isEmpty else { return false }
        if !known.isEmpty {
            return current.allSatisfy { !known.contains($0.description) }
        }
        guard let ip = LocalSubnet.parseIPv4(serverHost) else { return false }
        return current.allSatisfy { !$0.contains(ip) }
    }
}
