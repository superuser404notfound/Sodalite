import Foundation
import Network

/// An IPv4 subnet this device is attached to over Wi-Fi or Ethernet, read off the interface itself.
///
/// Two questions need it, and neither can be answered from the path alone. Whether Local Network
/// access is denied is a question about the DEVICE, so it has to be asked of an address that is on
/// the network the device is standing on, not of a server that may be at home while the phone sits
/// on a car's CarPlay Wi-Fi (the scoped probe reports a home address as denied there, and on
/// cellular too). And whether that Wi-Fi is the one the server lives on is answered by comparing it
/// against the subnets the server has answered from before.
///
/// A subnet, not an SSID: reading the SSID needs a location grant and an entitlement for a question
/// the address plan answers well enough. Two networks sharing a plan (a car and a home both on
/// 192.168.1.0/24) read as the same network, which only ever makes the app say less, never
/// something false.
nonisolated struct LocalSubnet: Hashable, Sendable, CustomStringConvertible {
    let address: UInt32
    let mask: UInt32

    var network: UInt32 { address & mask }

    /// Stable identity for persistence, `192.168.1.0/24`.
    var description: String { "\(Self.format(network))/\(mask.nonzeroBitCount)" }

    func contains(_ ip: UInt32) -> Bool { ip & mask == network }

    /// An address on this subnet that is not this device: the first host, or the second when the
    /// device holds the first. Only ever used as a target the permission governs; whether anything
    /// answers there does not matter.
    var controlTarget: String? {
        guard mask != .max, mask.nonzeroBitCount < 31 else { return nil }
        let first = network &+ 1
        return Self.format(first == address ? first &+ 1 : first)
    }

    /// The subnets on the Wi-Fi and Ethernet interfaces this path offers.
    static func current(interfaceNames: Set<String>) -> [LocalSubnet] {
        guard !interfaceNames.isEmpty else { return [] }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [LocalSubnet] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr, let netmask = ifa.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  interfaceNames.contains(String(cString: ifa.ifa_name))
            else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // A link-local 169.254 address is what an interface holds while it has no network.
            guard mask != 0, ip >> 16 != 0xA9FE else { continue }
            found.append(LocalSubnet(address: ip, mask: mask))
        }
        return found
    }

    /// The subnets of the path as it stands now.
    static func current(path: NWPath) -> [LocalSubnet] {
        let names = path.availableInterfaces
            .filter { $0.type == .wifi || $0.type == .wiredEthernet }
            .map(\.name)
        return current(interfaceNames: Set(names))
    }

    static func parseIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    static func format(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }
}
