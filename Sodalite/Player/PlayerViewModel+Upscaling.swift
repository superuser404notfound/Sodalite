import AetherEngine
import Foundation

/// Sodalite#223: Enhanced Upscaling on or off for the video that is playing, without touching the
/// setting. The chip exists only while the engine upscales this session or the viewer turned it off.
extension PlayerViewModel {
    enum UpscaleToggleState: Equatable {
        case on, reduced, off
    }

    var effectiveEnhancedUpscaling: Bool { upscalingOverride ?? preferences.enhancedUpscaling }

    var upscaleToggleState: UpscaleToggleState? {
        Self.upscaleToggleState(
            isUpscaling: upscaleStatus != nil,
            degraded: upscaleStatus?.degraded ?? false,
            stageDisabled: upscaleStatus?.disabledReason != nil,
            override: upscalingOverride)
    }

    /// A stage that switched itself off is latched for the session by the engine, so it offers
    /// nothing to undo. `override == true` keeps the chip up across the rebuild, before the first
    /// upscaled frame publishes a status again.
    static func upscaleToggleState(
        isUpscaling: Bool, degraded: Bool, stageDisabled: Bool, override: Bool?
    ) -> UpscaleToggleState? {
        if override == false { return .off }
        if stageDisabled { return nil }
        if isUpscaling { return degraded ? .reduced : .on }
        return override == true ? .on : nil
    }

    /// Filled while the stage runs, outline once the viewer turned it off, as the setting's own glyph.
    var upscaleChipIcon: String {
        upscaleToggleState == .off ? "wand.and.sparkles" : "wand.and.sparkles.inverse"
    }

    var upscaleChipLabel: String {
        switch upscaleToggleState {
        case .reduced: String(localized: "player.upscaling.reduced", defaultValue: "Upscaling Reduced")
        case .off: String(localized: "player.upscaling.off", defaultValue: "Upscaling Off")
        case .on, nil: String(localized: "player.upscaling.on", defaultValue: "Upscaling On")
        }
    }

    func toggleUpscaling() {
        guard let state = upscaleToggleState, upscaleToggleTask == nil else { return }
        let enable = state == .off
        let previous = upscalingOverride
        upscalingOverride = enable
        LogTap.shared.note("[Upscale] viewer turned it \(enable ? "on" : "off") for this video")
        upscaleToggleTask = Task { [weak self] in
            guard let self else { return }
            defer { upscaleToggleTask = nil }
            do {
                try await player.reloadAtCurrentPosition { $0.upscalesLowResolutionVideo = enable }
            } catch AetherEngineError.sessionNotReloadable(.upscaleRouteNeedsFreshLoad) where isLiveSession {
                // A live source keeps its route on a rebuild; the load that decides it again is a retune.
                await retuneLiveStream()
            } catch is CancellationError {
            } catch {
                LogTap.shared.note("[Upscale] toggle refused: \(error)")
                upscalingOverride = previous
            }
        }
        scheduleControlsHide()
    }

    func resetUpscaleOverride() {
        upscaleToggleTask?.cancel()
        upscaleToggleTask = nil
        upscalingOverride = nil
        upscaleStatus = nil
    }
}
