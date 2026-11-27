import Foundation
import Testing
@testable import Sodalite

/// Addons pick a stream variant per device by the `Device` field Jellyfin forwards (Sodalite#260),
/// so each platform has to send its own type, and the same one every time.
@Suite("Device type in the MediaBrowser header")
struct ClientDeviceTests {

    @Test("an iPad model reads as iPad, every other iOS model as iPhone")
    func iOSMapping() {
        #expect(ClientDevice.iOSName(modelIdentifier: "iPad16,3", isiOSAppOnMac: false) == "iPad")
        #expect(ClientDevice.iOSName(modelIdentifier: "iPhone17,1", isiOSAppOnMac: false) == "iPhone")
        #expect(ClientDevice.iOSName(modelIdentifier: "", isiOSAppOnMac: false) == "iPhone")
    }

    @Test("the iOS app on a Mac or a Vision Pro does not pass for a phone")
    func iOSAppOnOtherHardware() {
        #expect(ClientDevice.iOSName(modelIdentifier: "iPad16,3", isiOSAppOnMac: true) == "Mac")
        #expect(ClientDevice.iOSName(modelIdentifier: "RealityDevice14,1", isiOSAppOnMac: false) == "Apple Vision Pro")
    }

    #if os(tvOS)
    @Test("the Apple TV still sends Apple TV")
    func appleTV() {
        #expect(ClientDevice.name == "Apple TV")
        // The iOS mapping reads this, and the simulator reports the host's "arm64" unless the
        // simulated model is picked up.
        #expect(ClientDevice.modelIdentifier.hasPrefix("AppleTV"))
        #expect(JellyfinClient().buildAuthHeader().contains(#"Device="Apple TV""#))
    }
    #endif
}
