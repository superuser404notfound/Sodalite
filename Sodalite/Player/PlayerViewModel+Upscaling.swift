import AetherEngine
import Foundation

/// Sodalite#223: Enhanced Upscaling on or off for the video that is playing, without touching the
/// setting. The chip exists only while the engine upscales this session or the viewer turned it off.
extension PlayerViewModel {
    enum UpscaleToggleState: Equatable {
        case on, off
    }

    var effectiveEnhancedUpscaling: Bool { upscalingOverride ?? preferences.enhancedUpscaling }

    /// AetherEngine#1039: the scaler for this load. The line-art scaler only for drawn content, which the
    /// genres say. A Jellyfin episode carries none of its own, so its series' are read, once per series.
    func upscaleScalerForLoad() async -> UpscaleScaler {
        guard effectiveEnhancedUpscaling, preferences.lineArtUpscaling else { return .automatic }
        var genres = item.genres ?? []
        if genres.isEmpty, let seriesID = item.seriesId {
            if let cached = Self.seriesIsAnimation[seriesID] { return cached ? .lineArt : .automatic }
            if let itemService, let series = try? await itemService.getItemDetail(userID: userID, itemID: seriesID) {
                genres = series.genres ?? []
                Self.seriesIsAnimation[seriesID] = Self.isAnimation(genres: genres)
            }
        }
        let animated = Self.isAnimation(genres: genres)
        LogTap.shared.note("[Upscale] scaler \(animated ? "line art" : "automatic") (genres: \(genres.joined(separator: ", ")))")
        return animated ? .lineArt : .automatic
    }

    /// The live paths have no series to ask: a programme's own genres decide.
    var liveUpscaleScaler: UpscaleScaler {
        effectiveEnhancedUpscaling && preferences.lineArtUpscaling && Self.isAnimation(genres: item.genres ?? [])
            ? .lineArt : .automatic
    }

    /// Server metadata names genres in the library's language, so the common translations of Animation and
    /// Anime count. Compared case and diacritic insensitively.
    static func isAnimation(genres: [String]) -> Bool {
        genres.contains { genre in
            let folded = genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return animationGenreNames.contains(folded)
        }
    }

    static let animationGenreNames: Set<String> = [
        "animation", "anime", "animacion", "animacao", "animazione", "animatie", "animacja", "animace",
        "animacia", "animacio", "animasjon", "animering", "animaatio", "animasyon", "animasi", "animaatiot",
        "анимация", "мультфильм", "анімація", "аниме", "κινουμενα σχεδια", "アニメ", "アニメーション", "动画", "動畫",
        "动漫", "애니메이션", "애니", "אנימציה", "رسوم متحركة", "انیمیشن", "แอนิเมชัน", "hoạt hình",
    ]

    /// Per process: a series' genres do not change between its episodes.
    @MainActor static var seriesIsAnimation: [String: Bool] = [:]

    var upscaleToggleState: UpscaleToggleState? {
        Self.upscaleToggleState(
            isUpscaling: upscaleStatus != nil,
            stageDisabled: upscaleStatus?.disabledReason != nil,
            override: upscalingOverride)
    }

    /// A stage that switched itself off is latched for the session by the engine, so it offers
    /// nothing to undo. `override == true` keeps the chip up across the rebuild, before the first
    /// upscaled frame publishes a status again. A degraded stage still reads On: the viewer cannot
    /// pick or undo it, and Stats for Nerds already shows it.
    static func upscaleToggleState(
        isUpscaling: Bool, stageDisabled: Bool, override: Bool?
    ) -> UpscaleToggleState? {
        if override == false { return .off }
        if stageDisabled { return nil }
        if isUpscaling || override == true { return .on }
        return nil
    }

    /// Filled while the stage runs, outline once the viewer turned it off, as the setting's own glyph.
    var upscaleChipIcon: String {
        upscaleToggleState == .off ? "wand.and.sparkles" : "wand.and.sparkles.inverse"
    }

    var upscaleChipLabel: String {
        switch upscaleToggleState {
        case .off: String(localized: "player.upscaling.off", defaultValue: "Upscaling Off")
        case .on, nil: String(localized: "player.upscaling.on", defaultValue: "Upscaling On")
        }
    }

    func toggleUpscaling() {
        guard let state = upscaleToggleState, upscaleToggleTask == nil else { return }
        let enable = state == .off
        let previous = upscalingOverride
        upscalingOverride = enable
        upscaleToggleGeneration += 1
        let generation = upscaleToggleGeneration
        LogTap.shared.note("[Upscale] viewer turned it \(enable ? "on" : "off") for this video")
        upscaleToggleTask = Task { [weak self] in
            guard let self else { return }
            defer { if upscaleToggleGeneration == generation { upscaleToggleTask = nil } }
            do {
                try await player.reloadAtCurrentPosition { $0.upscalesLowResolutionVideo = enable }
            } catch AetherEngineError.sessionNotReloadable(.upscaleRouteNeedsFreshLoad) where isLiveSession {
                // A live source keeps its route on a rebuild; the load that decides it again is a retune.
                await retuneLiveStream()
            } catch is CancellationError {
            } catch {
                LogTap.shared.note("[Upscale] toggle refused: \(error)")
                guard upscaleToggleGeneration == generation else { return }
                upscalingOverride = previous
            }
        }
        scheduleControlsHide()
    }

    func resetUpscaleOverride() {
        upscaleToggleTask?.cancel()
        upscaleToggleTask = nil
        upscaleToggleGeneration += 1
        upscalingOverride = nil
        upscaleStatus = nil
    }
}
