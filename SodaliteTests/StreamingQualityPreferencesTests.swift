import Foundation
import Testing
@testable import Sodalite

@Suite("Streaming quality preferences", .serialized)
@MainActor
struct StreamingQualityPreferencesTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "streamingQuality.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func bothDefaultsStartAtOriginal() {
        let device = DevicePreferences(store: scratch("fresh"))
        #expect(device.streamingQualityWifi == .original)
        #expect(device.streamingQualityCellular == .original)
    }

    /// Sodalite#87: the rung describes this device's connection, so every profile on it shares it,
    /// under an unprefixed key.
    @Test func theRungIsADeviceValueSharedByProfiles() {
        let defaults = scratch("shared")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)

        alice.streamingQualityCellular = .mbps4

        #expect(bob.streamingQualityCellular == .mbps4)
        #expect(defaults.string(forKey: "playback.streamingQualityCellular") == "mbps4")
        #expect(defaults.object(forKey: "s:alice/playback.streamingQualityCellular") == nil)
    }

    @Test func aStoredRungSurvivesARelaunch() {
        let defaults = scratch("relaunch")
        DevicePreferences(store: defaults).streamingQualityWifi = .mbps20
        #expect(DevicePreferences(store: defaults).streamingQualityWifi == .mbps20)
    }

    @Test func anUnknownStoredValueFallsBackToOriginal() {
        let defaults = scratch("garbage")
        defaults.set("mbps3000", forKey: "playback.streamingQualityWifi")
        #expect(DevicePreferences(store: defaults).streamingQualityWifi == .original)
    }

    @Test func theDefaultFollowsThePath() {
        let defaults = scratch("path")
        let prefs = PlaybackPreferences(store: defaults)
        prefs.streamingQualityWifi = .mbps20
        prefs.streamingQualityCellular = .mbps2
        let metered = NetworkPathSnapshot.Reading(isSatisfied: true, usesLocalInterface: false,
                                                  hasLocalInterface: false, isMetered: true)
        #if os(tvOS)
        #expect(prefs.defaultStreamingQuality(reading: metered) == .mbps20)
        #else
        #expect(prefs.defaultStreamingQuality(reading: metered) == .mbps2)
        #endif
        #expect(prefs.defaultStreamingQuality(reading: nil) == .mbps20)
    }
}
