import CoreGraphics
import Foundation
import Testing
@testable import Sodalite

@Suite("Enhanced Upscaling (AetherEngine#846)", .serialized)
@MainActor
struct EnhancedUpscalingTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "enhancedUpscaling.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToOffAndPersistsAsADeviceValue() {
        let defaults = scratch("persist")
        let device = DevicePreferences(store: defaults)
        #expect(device.enhancedUpscaling == false)

        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        alice.enhancedUpscaling = true

        #expect(defaults.bool(forKey: "playback.enhancedUpscaling"))
        #expect(PlaybackPreferences(store: defaults, scope: "s:bob", device: device).enhancedUpscaling)
        #expect(DevicePreferences(store: defaults).enhancedUpscaling)
    }

    @Test func statsLabelNamesTheStagesThatRun() {
        let sd = CGSize(width: 720, height: 480)
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: sd, mlScale: 2, targetSize: CGSize(width: 2880, height: 2160),
            degraded: false, disabledReason: nil) == "720×480 → ML 2x → MetalFX → 2880×2160")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: sd, mlScale: 2, targetSize: CGSize(width: 1440, height: 960),
            degraded: true, disabledReason: nil) == "720×480 → ML 2x → 1440×960")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: sd, mlScale: 2, targetSize: CGSize(width: 1440, height: 960),
            degraded: false, disabledReason: nil) == "720×480 → ML 2x → 1440×960")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: CGSize(width: 1280, height: 720), mlScale: nil, targetSize: CGSize(width: 3840, height: 2160),
            degraded: false, disabledReason: nil) == "1280×720 → MetalFX → 3840×2160")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: CGSize(width: 1280, height: 720), mlScale: nil, targetSize: CGSize(width: 1280, height: 720),
            degraded: true, disabledReason: nil) == "1280×720 → 1280×720")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: sd, mlScale: 2, targetSize: CGSize(width: 2880, height: 2160),
            degraded: false, disabledReason: "frame budget overrun") == "off (frame budget overrun)")
    }
}
