import Foundation
import Testing
import AetherEngine
@testable import Sodalite

@Suite("Device values split from profile values", .serialized)
@MainActor
struct DevicePreferencesSplitTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "deviceSplit.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func twoProfilesDoNotShareTheirOwnValues() {
        let defaults = scratch("isolation")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)

        alice.subtitleFontSize = .xlarge

        #expect(bob.subtitleFontSize == .medium)
        #expect(PlaybackPreferences(store: defaults, scope: "s:alice", device: device).subtitleFontSize == .xlarge)
        #expect(defaults.string(forKey: "playback.subtitleFontSize") == nil)
    }

    @Test func deviceValuesAreSharedAndKeepTheirOldKeys() {
        let defaults = scratch("shared")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)
        let aliceLook = AppearancePreferences(store: defaults, scope: "s:alice", device: device)

        alice.networkBufferDepth = .maximum
        aliceLook.showTopShelfRow = false

        #expect(bob.networkBufferDepth == .maximum)
        #expect(defaults.string(forKey: "playback.networkBufferDepth") == "maximum")
        #expect(defaults.object(forKey: "appearance.showTopShelfRow") as? Bool == false)
        #expect(defaults.object(forKey: "s:alice/playback.networkBufferDepth") == nil)
    }

    /// Vincent, 2026-09-17: how a person drives the remote is theirs, not the box's.
    @Test func touchpadScrubbingBelongsToTheProfile() {
        let defaults = scratch("touchpad")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)

        alice.touchpadScrubbing = false

        #expect(bob.touchpadScrubbing)
        #expect(defaults.object(forKey: "s:alice/playback.touchpadScrubbing") as? Bool == false)
        #expect(defaults.object(forKey: "playback.touchpadScrubbing") == nil)
    }

    @Test func anUpgradedDeviceReadsItsDeviceValuesFromTheOldKeys() {
        let defaults = scratch("upgrade")
        defaults.set("unlimited", forKey: "playback.networkBufferDepth")
        defaults.set(false, forKey: "playback.preferLosslessAudioBridge")

        let device = DevicePreferences(store: defaults)

        #expect(device.networkBufferDepth == .unlimited)
        #expect(!device.preferLosslessAudioBridge)
    }

    /// Audit 2026-09-25 CS-6: a reset wipes the store, and the object in memory kept the old values
    /// until a relaunch, so the player ran on the old buffers and the Top Shelf switch disagreed.
    @Test func aReloadAfterAWipeLandsOnTheDefaults() {
        let suite = "deviceSplit.reload"
        let defaults = scratch("reload")
        let device = DevicePreferences(store: defaults)
        let virgin = DevicePreferences(store: scratch("reloadVirgin"))
        device.showTopShelfRow = false
        device.networkBufferDepth = .maximum
        device.preferLosslessAudioBridge = true
        device.forceDolbyVisionOnNonDVDisplay = true
        device.showStatsForNerds = true

        defaults.removePersistentDomain(forName: suite)
        device.reloadFromStore()

        #expect(device.showTopShelfRow == virgin.showTopShelfRow)
        #expect(device.networkBufferDepth == virgin.networkBufferDepth)
        #expect(device.preferLosslessAudioBridge == virgin.preferLosslessAudioBridge)
        #expect(device.forceDolbyVisionOnNonDVDisplay == virgin.forceDolbyVisionOnNonDVDisplay)
        #expect(device.showStatsForNerds == virgin.showStatsForNerds)
    }
}
