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

    /// Audit 2026-11-17 SYNC-R201: `reloadFromStore` lists its fields by hand. Every stored value is
    /// moved off its default here, so one that misses the list stays put after the wipe and fails,
    /// and the name check fails first when a field is added without extending this test.
    @Test func aReloadAfterAWipeCoversEveryDeviceField() {
        let suite = "deviceSplit.reloadAll"
        let defaults = scratch("reloadAll")
        let device = DevicePreferences(store: defaults)
        let virgin = DevicePreferences(store: scratch("reloadAllVirgin"))

        func other<T: CaseIterable & Equatable>(_ value: T) -> T { Array(T.allCases).last { $0 != value } ?? value }
        device.showStatsForNerds.toggle()
        device.showEngineDiagnostics.toggle()
        device.preferLosslessAudioBridge.toggle()
        device.trueHDAtmosHeights.toggle()
        device.objectAudioLayout = other(device.objectAudioLayout)
        device.playerRotationLocked.toggle()
        device.networkBufferDepth = other(device.networkBufferDepth)
        device.liveBufferDepth = other(device.liveBufferDepth)
        device.liveDelay = other(device.liveDelay)
        device.liveTeletextPage = other(device.liveTeletextPage)
        device.streamingQualityWifi = other(device.streamingQualityWifi)
        device.streamingQualityCellular = other(device.streamingQualityCellular)
        device.forceDolbyVisionOnNonDVDisplay.toggle()
        device.preferHDR10PlusOverForcedDolbyVision.toggle()
        device.enhancedUpscaling.toggle()
        device.lineArtUpscaling.toggle()
        device.fullHDUpscaling.toggle()
        device.showTopShelfRow.toggle()
        device.topShelfImage = other(device.topShelfImage)
        device.speakerLayout = other(device.speakerLayout)
        device.dialogueBoost = other(device.dialogueBoost)
        device.nightMode = other(device.nightMode)
        device.nightModeStartHour = 3
        device.nightModeEndHour = 11
        device.lfeInStereoDownmix.toggle()
        device.audioDelayMilliseconds = 120

        let names = Set(Mirror(reflecting: device).children.compactMap(\.label)
            .filter { $0.hasPrefix("_") && $0 != "_$observationRegistrar" }.map { String($0.dropFirst()) })
        #expect(names.count == 26)

        defaults.removePersistentDomain(forName: suite)
        device.reloadFromStore()

        for (mine, theirs) in zip(Mirror(reflecting: device).children, Mirror(reflecting: virgin).children)
        where mine.label?.hasPrefix("_") == true && mine.label != "_$observationRegistrar" {
            #expect("\(mine.value)" == "\(theirs.value)", "\(mine.label ?? "?") survived the reload")
        }
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
