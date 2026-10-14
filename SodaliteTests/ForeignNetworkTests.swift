import Foundation
import Testing
@testable import Sodalite

/// A phone on a Wi-Fi its server does not live on, the reported case being a car's CarPlay Wi-Fi.
/// The claim "you are on the wrong network" may only be made where it cannot be the home network
/// with the server switched off.
@Suite("Foreign local network")
struct ForeignNetworkTests {
    private let lanURL = URL(string: "http://192.168.1.50:8096")!
    private let home = LocalSubnet(address: LocalSubnet.parseIPv4("192.168.1.23")!, mask: 0xFFFF_FF00)
    private let car = LocalSubnet(address: LocalSubnet.parseIPv4("10.20.0.7")!, mask: 0xFFFF_FF00)

    // MARK: Subnet arithmetic

    @Test func subnetIdentityIsTheNetworkAndPrefix() {
        #expect(home.description == "192.168.1.0/24")
    }

    @Test func containsOnlyItsOwnRange() {
        #expect(home.contains(LocalSubnet.parseIPv4("192.168.1.50")!))
        #expect(!home.contains(LocalSubnet.parseIPv4("192.168.2.50")!))
    }

    @Test func theControlTargetIsNeverTheDeviceItself() {
        #expect(home.controlTarget == "192.168.1.1")
        let gateway = LocalSubnet(address: LocalSubnet.parseIPv4("192.168.1.1")!, mask: 0xFFFF_FF00)
        #expect(gateway.controlTarget == "192.168.1.2")
    }

    @Test func aPointToPointLinkHasNoControlTarget() {
        #expect(LocalSubnet(address: 1, mask: 0xFFFF_FFFF).controlTarget == nil)
    }

    @Test func parsingRejectsNames() {
        #expect(LocalSubnet.parseIPv4("jellyfin.local") == nil)
        #expect(LocalSubnet.parseIPv4("192.168.1") == nil)
    }

    // MARK: Is this Wi-Fi a foreign one

    @Test func aNetworkTheServerNeverAnsweredFromIsForeign() {
        #expect(ServerHomeNetworks.isForeign(current: [car], known: ["192.168.1.0/24"], serverHost: "192.168.1.50"))
    }

    /// Home with the server switched off: the network is known, so it stays a plain outage.
    @Test func theHomeNetworkIsNeverForeign() {
        #expect(!ServerHomeNetworks.isForeign(current: [home], known: ["192.168.1.0/24"], serverHost: "192.168.1.50"))
    }

    @Test func withoutHistoryAnAddressOutsideEverySubnetIsForeign() {
        #expect(ServerHomeNetworks.isForeign(current: [car], known: [], serverHost: "192.168.1.50"))
    }

    @Test func withoutHistoryAnAddressOnThisSubnetIsNotForeign() {
        #expect(!ServerHomeNetworks.isForeign(current: [home], known: [], serverHost: "192.168.1.50"))
    }

    @Test func withoutHistoryANameSaysNothing() {
        #expect(!ServerHomeNetworks.isForeign(current: [car], known: [], serverHost: "jellyfin.local"))
    }

    @Test func noReadableSubnetSaysNothing() {
        #expect(!ServerHomeNetworks.isForeign(current: [], known: ["192.168.1.0/24"], serverHost: "192.168.1.50"))
    }

    @Test func recordingKeepsTheNewestFirstAndBounded() {
        let defaults = UserDefaults(suiteName: "ForeignNetworkTests-\(UUID().uuidString)")!
        for third in 0..<10 {
            let subnet = LocalSubnet(address: LocalSubnet.parseIPv4("10.0.\(third).5")!, mask: 0xFFFF_FF00)
            ServerHomeNetworks.record([subnet], serverID: "s", defaults: defaults)
        }
        let known = ServerHomeNetworks.known(serverID: "s", defaults: defaults)
        #expect(known.count == 8)
        #expect(known.contains("10.0.9.0/24"))
        #expect(!known.contains("10.0.0.0/24"))
    }

    // MARK: The verdict

    @Test func aForeignWiFiGetsItsOwnVerdict() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true, isOnAForeignLocalNetwork: true
        ) == .foreignNetwork)
    }

    @Test func aKnownWiFiStaysUnreachable() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true, isOnAForeignLocalNetwork: false
        ) == .unreachable)
    }

    /// Cellular only keeps the older, more specific sentence.
    @Test func cellularStaysOffNetwork() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: false, isOnAForeignLocalNetwork: true
        ) == .offNetwork)
    }

    @Test func aServerWithARemoteSlotIsNotMissingOne() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: false, hasAlternateSlot: true,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true, isOnAForeignLocalNetwork: true
        ) == .unreachable)
    }

    @Test func anAnswerStillWins() {
        #expect(ServerReachability.classify(
            probedURL: lanURL, answered: true, hasAlternateSlot: false,
            pathIsSatisfied: true, isAttachedToALocalNetwork: true, isOnAForeignLocalNetwork: true
        ) == .reachable)
    }
}
