import AetherEngine
import Foundation

extension PlayerViewModel {
    /// Left-to-right order of the VOD transport buttons. Built from the same gates TransportBar
    /// renders with: the two must agree, else left/right focus lands on an unrendered button.
    /// Live has its own two-button row (LiveTransportBar) and does not use this.
    static func transportFocusOrder(
        hasSkippableSegment: Bool,
        hasNextEpisodePrompt: Bool,
        episodeCount: Int,
        chapterCount: Int,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        hasQualityChoice: Bool,
        isPiPAvailable: Bool,
        showsStats: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = [.restartButton]
        if hasSkippableSegment { order.append(.skipSegmentButton) }
        // Next to the skip button on purpose: both are "press once to move forward", and the two
        // trade places across an episode seam (Sodalite#103).
        if hasNextEpisodePrompt { order.append(.nextEpisodeButton) }
        if episodeCount > 1 { order.append(.episodeButton) }
        if chapterCount > 1 { order.append(.chapterButton) }
        if hasAudioTracks { order.append(.audioButton) }
        if hasSubtitles { order.append(.subtitleButton) }
        if hasQualityChoice { order.append(.qualityButton) }
        order.append(.speedButton)
        order.append(.pictureButton)
        if isPiPAvailable { order.append(.pipButton) }
        if showsStats { order.append(.infoButton) }
        return order
    }

    /// Left-to-right order of the LIVE transport controls (LiveTransportBar). Same contract as the
    /// VOD order above: the bar renders from these gates, so a button missing here is a dead stop
    /// under left/right, and a button missing there is focus on nothing. Track order follows the VOD
    /// bar (audio, then subtitles) so both players read the same way.
    static func liveTransportFocusOrder(
        isAtLiveEdge: Bool,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        isPiPAvailable: Bool,
        offersMultiview: Bool,
        showsStats: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = []
        // Return to Live exists only while behind the edge; at the edge there is nothing to return to.
        if !isAtLiveEdge { order.append(.returnToLiveButton) }
        if hasAudioTracks { order.append(.audioButton) }
        if hasSubtitles { order.append(.subtitleButton) }
        if isPiPAvailable { order.append(.pipButton) }
        if offersMultiview { order.append(.multiviewButton) }
        if showsStats { order.append(.infoButton) }
        return order
    }

    /// The VOD order for the current session, gated exactly as TransportBar renders. Reading the
    /// order instead of restating its gates is what keeps focus off a button that is not there.
    var transportFocusOrder: [ControlsFocus] {
        Self.transportFocusOrder(
            hasSkippableSegment: activeSkipSegment != nil,
            hasNextEpisodePrompt: showNextEpisodeOverlay && nextEpisode != nil,
            episodeCount: seasonEpisodes.count,
            chapterCount: chapters.count,
            hasAudioTracks: !player.audioTracks.isEmpty,
            hasSubtitles: !subtitleStreams.isEmpty || supportsSubtitleSearch,
            hasQualityChoice: supportsQualityChoice,
            isPiPAvailable: isPiPAvailable,
            showsStats: preferences.showStatsForNerds)
    }

    /// The live order for the current session, gated exactly as LiveTransportBar renders.
    var liveTransportFocusOrder: [ControlsFocus] {
        Self.liveTransportFocusOrder(
            isAtLiveEdge: isAtLiveEdge,
            hasAudioTracks: !displayAudioTracks.isEmpty,
            hasSubtitles: !displaySubtitleStreams.isEmpty,
            isPiPAvailable: isPiPAvailable,
            offersMultiview: offersMultiview,
            showsStats: preferences.showStatsForNerds)
    }
}
