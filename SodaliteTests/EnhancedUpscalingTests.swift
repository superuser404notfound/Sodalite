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

    @Test func lineArtLabelNamesTheResampleOnlyWhenTwoTimesMisses() {
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: CGSize(width: 1920, height: 1080), mlScale: nil, targetSize: CGSize(width: 3840, height: 2160),
            degraded: false, disabledReason: nil, lineArt: true) == "1920×1080 → Restore → Line Art 2x → 3840×2160")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: CGSize(width: 1920, height: 1080), mlScale: nil, targetSize: CGSize(width: 3840, height: 2160),
            degraded: true, disabledReason: nil, lineArt: true) == "1920×1080 → Line Art 2x → 3840×2160")
        #expect(StatsOverlayView.upscaleLabel(
            sourceSize: CGSize(width: 1280, height: 720), mlScale: nil, targetSize: CGSize(width: 3840, height: 2160),
            degraded: false, disabledReason: nil, lineArt: true) == "1280×720 → Restore → Line Art 2x → Bilinear → 3840×2160")
    }

    /// AetherEngine#1039: the picker is two device switches, and the line-art one means nothing while
    /// upscaling is off.
    @Test func pickerMapsOntoTheTwoSwitches() {
        let defaults = scratch("mode")
        let device = DevicePreferences(store: defaults)
        let prefs = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        #expect(prefs.upscalingMode == .off)
        prefs.upscalingMode = .withAnimation
        #expect(device.enhancedUpscaling && device.lineArtUpscaling)
        #expect(DevicePreferences(store: defaults).lineArtUpscaling)
        prefs.upscalingMode = .on
        #expect(device.enhancedUpscaling && !device.lineArtUpscaling)
        prefs.upscalingMode = .off
        #expect(!device.enhancedUpscaling && !device.lineArtUpscaling)
        #expect(EnhancedUpscalingMode(enhanced: false, lineArt: true) == .off)
    }

    @Test(arguments: [
        (["Science Fiction", "Animation"], true), (["Anime"], true), (["Animación", "Familia"], true),
        (["アニメ"], true), (["Мультфильм"], true), (["ANIMATION"], true),
        (["Drama", "Comedy"], false), ([], false), (["Animal Planet"], false),
    ])
    func animationIsReadFromTheGenres(genres: [String], expected: Bool) {
        #expect(PlayerViewModel.isAnimation(genres: genres) == expected)
    }
}
