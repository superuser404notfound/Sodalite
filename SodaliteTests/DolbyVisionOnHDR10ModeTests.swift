import Foundation
import Testing
@testable import Sodalite

/// Sodalite#245: "Dolby Vision on HDR10 Displays" is a picker over two device values now, so an
/// HDR10+ TV can keep a file's own HDR10+ while every other Profile 8.1 still gets the DV route.
@Suite("Dolby Vision on HDR10 displays, HDR10+ first (Sodalite#245)", .serialized)
@MainActor
struct DolbyVisionOnHDR10ModeTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "dolbyVisionOnHDR10Mode.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultIsHDR10PlusFirstOnTVOnly() {
        let prefs = PlaybackPreferences(store: scratch("default"), scope: "s:alice",
                                        device: DevicePreferences(store: scratch("default")))
        #if os(tvOS)
        #expect(prefs.dolbyVisionOnHDR10Mode == .hdr10PlusFirst)
        #else
        #expect(prefs.dolbyVisionOnHDR10Mode == .off)
        #endif
    }

    /// A viewer who switched the old toggle on by hand gets HDR10+ first on tvOS too: the new value
    /// has no stored answer yet, and that was the reporter's own setup.
    @Test func anOldExplicitOnKeepsTheRouteOn() {
        let defaults = scratch("legacyOn")
        defaults.set(true, forKey: "playback.forceDolbyVisionOnNonDVDisplay")
        let device = DevicePreferences(store: defaults)
        #expect(device.forceDolbyVisionOnNonDVDisplay)
        #expect(device.preferHDR10PlusOverForcedDolbyVision == DevicePreferences.preferHDR10PlusOverForcedDolbyVisionDefault)
    }

    @Test func pickerMapsOntoTheTwoValuesAndPersists() {
        let defaults = scratch("mode")
        let device = DevicePreferences(store: defaults)
        let prefs = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)

        prefs.dolbyVisionOnHDR10Mode = .on
        #expect(device.forceDolbyVisionOnNonDVDisplay && !device.preferHDR10PlusOverForcedDolbyVision)
        prefs.dolbyVisionOnHDR10Mode = .hdr10PlusFirst
        #expect(device.forceDolbyVisionOnNonDVDisplay && device.preferHDR10PlusOverForcedDolbyVision)
        #expect(DevicePreferences(store: defaults).preferHDR10PlusOverForcedDolbyVision)
        prefs.dolbyVisionOnHDR10Mode = .off
        #expect(!device.forceDolbyVisionOnNonDVDisplay && !device.preferHDR10PlusOverForcedDolbyVision)
        #expect(!DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay)

        // The HDR10+ half means nothing while the route is off.
        #expect(DolbyVisionOnHDR10Mode(force: false, preferHDR10Plus: true) == .off)
    }

    @Test func aDeviceValueIsSharedByEveryProfile() {
        let defaults = scratch("shared")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)
        alice.dolbyVisionOnHDR10Mode = .on
        #expect(bob.dolbyVisionOnHDR10Mode == .on)
        #expect(defaults.object(forKey: "s:alice/playback.preferHDR10PlusOverForcedDolbyVision") == nil)
    }
}
