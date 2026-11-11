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

    /// AetherEngine#1018: on tvOS a panel in HDR10 ignores the RPU unless the Profile 5 route composes it,
    /// so the route is on unless the viewer chose otherwise. A stored value always wins.
    @Test func dolbyVisionOnHDR10DisplaysDefaultsOnForTVOnlyAndKeepsAChoice() {
        let defaults = scratch("forceDV")
        #if os(tvOS)
        #expect(DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay)
        #else
        #expect(!DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay)
        #endif
        DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay = false
        #expect(!DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay)
        DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay = true
        #expect(DevicePreferences(store: defaults).forceDolbyVisionOnNonDVDisplay)
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

    /// AetherEngine#731, 2026-10-17: object rendering is opt-in until the patent question is settled.
    /// The heights row is one picker over two stored values: off keeps the chosen layout, so turning
    /// heights back on returns to it, and the layout is a device value with its own key.
    @Test func heightChannelLayoutDefaultsTo916AndSurvivesOff() {
        let defaults = scratch("bedLayout")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        #expect(alice.heightChannelLayout == .l916)
        #expect(alice.objectAudioRendering == .render(.l916))

        alice.heightChannelLayout = .l714
        #expect(alice.objectAudioRendering == .render(.l714))
        #expect(defaults.string(forKey: "playback.objectAudioLayout") == "7.1.4")
        #expect(defaults.object(forKey: "s:alice/playback.objectAudioLayout") == nil)

        alice.heightChannelLayout = nil
        #expect(alice.objectAudioRendering == .off)
        #expect(!device.trueHDAtmosHeights)
        #expect(device.objectAudioLayout == .l714)

        device.trueHDAtmosHeights = true
        #expect(DevicePreferences(store: defaults).objectAudioLayout == .l714)
        #expect(PlaybackPreferences(store: defaults, scope: "s:bob", device: device).heightChannelLayout == .l714)
    }

    @Test func trueHDAtmosHeightsAreOnByDefaultAndADeviceValue() {
        let defaults = scratch("atmosHeights")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)

        #expect(device.trueHDAtmosHeights)
        #expect(alice.objectAudioRendering == .render(.l916))

        alice.trueHDAtmosHeights = false

        #expect(bob.objectAudioRendering == .off)
        #expect(defaults.object(forKey: "playback.trueHDAtmosHeights") as? Bool == false)
        #expect(defaults.object(forKey: "s:alice/playback.trueHDAtmosHeights") == nil)

        defaults.removePersistentDomain(forName: "deviceSplit.atmosHeights")
        device.reloadFromStore()
        #expect(device.trueHDAtmosHeights, "a wiped store lands on the default again")
    }
}
