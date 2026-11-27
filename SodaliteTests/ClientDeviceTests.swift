import Foundation
import Testing
@testable import Sodalite

/// Addons pick a stream variant per device by the `Device` field Jellyfin forwards (Sodalite#260),
/// so each platform has to send its own type, and the same one every time.
@Suite("Device type in the MediaBrowser header")
struct ClientDeviceTests {

    @Test("an iPad model reads as iPad, every other iOS model as iPhone")
    func iOSMapping() {
        #expect(ClientDevice.name(modelIdentifier: "iPad16,3", isiOSAppOnMac: false) == "iPad")
        #expect(ClientDevice.name(modelIdentifier: "iPhone17,1", isiOSAppOnMac: false) == "iPhone")
        #expect(ClientDevice.name(modelIdentifier: "", isiOSAppOnMac: false) == "iPhone")
    }

    @Test("the iOS app running on a Mac reads as Mac, whatever model it reports")
    func iOSAppOnMac() {
        #expect(ClientDevice.name(modelIdentifier: "iPad16,3", isiOSAppOnMac: true) == "Mac")
    }

    #if os(tvOS)
    @Test("the Apple TV still sends Apple TV")
    func appleTV() {
        #expect(ClientDevice.name == "Apple TV")
        #expect(JellyfinClient().buildAuthHeader().contains(#"Device="Apple TV""#))
    }
    #endif
}
