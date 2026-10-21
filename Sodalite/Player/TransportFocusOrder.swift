import AetherEngine
import Foundation

extension PlayerViewModel {
    /// Left-to-right order of the VOD transport buttons. Built from the same gates TransportBar
    /// renders with: the bar draws exactly this list, else left/right focus lands on an unrendered
    /// button. Live has its own row (LiveTransportBar) and does not use this.
    ///
    /// `controls` is the viewer's arrangement (Sodalite#194). The two prompts lead, ahead of it: they
    /// are not in the list, and Up from the scrub bar is meant to find them first.
    static func transportFocusOrder(
        controls: [PlayerControl],
        hasSkippableSegment: Bool,
        hasNextEpisodePrompt: Bool,
        episodeCount: Int,
        chapterCount: Int,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        hasQualityChoice: Bool,
        isPiPAvailable: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = []
        if hasSkippableSegment { order.append(.skipSegmentButton) }
        // Next to the skip button on purpose: both are "press once to move forward", and the two
        // trade places across an episode seam (Sodalite#103).
        if hasNextEpisodePrompt { order.append(.nextEpisodeButton) }
        for control in controls {
            switch control {
            case .restart: order.append(.restartButton)
            case .episodes where episodeCount > 1: order.append(.episodeButton)
            case .chapters where chapterCount > 1: order.append(.chapterButton)
            case .audio where hasAudioTracks: order.append(.audioButton)
            case .subtitles where hasSubtitles: order.append(.subtitleButton)
            case .quality where hasQualityChoice: order.append(.qualityButton)
            case .speed: order.append(.speedButton)
            case .picture: order.append(.pictureButton)
            case .pip where isPiPAvailable: order.append(.pipButton)
            case .stats: order.append(.infoButton)
            default: break
            }
        }
        return order
    }

    /// Left-to-right order of the LIVE transport controls (LiveTransportBar). Same contract as the
    /// VOD order above: the bar renders this list, so the two cannot drift. Return to Live is the
    /// live prompt and leads, outside the viewer's arrangement.
    static func liveTransportFocusOrder(
        controls: [PlayerControl],
        isAtLiveEdge: Bool,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        isPiPAvailable: Bool,
        offersMultiview: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = []
        // Return to Live exists only while behind the edge; at the edge there is nothing to return to.
        if !isAtLiveEdge { order.append(.returnToLiveButton) }
        for control in controls {
            switch control {
            case .audio where hasAudioTracks: order.append(.audioButton)
            case .subtitles where hasSubtitles: order.append(.subtitleButton)
            case .pip where isPiPAvailable: order.append(.pipButton)
            case .multiview where offersMultiview: order.append(.multiviewButton)
            case .stats: order.append(.infoButton)
            default: break
            }
        }
        return order
    }

    /// Where Up from the scrub bar lands: the leftmost control, unless that is "From Start", which
    /// discards the resume position and is an unwanted first stop for a single press. nil when the
    /// viewer has hidden every control and no prompt is up.
    static func upLanding(in order: [ControlsFocus]) -> ControlsFocus? {
        order.first(where: { $0 != .restartButton }) ?? order.first
    }

    /// The VOD order for the current session, gated exactly as TransportBar renders. Reading the
    /// order instead of restating its gates is what keeps focus off a button that is not there.
    var transportFocusOrder: [ControlsFocus] {
        Self.transportFocusOrder(
            controls: preferences.playerControls.visibleControls(in: .transport),
            hasSkippableSegment: activeSkipSegment != nil,
            hasNextEpisodePrompt: showNextEpisodeOverlay && nextEpisode != nil,
            episodeCount: seasonEpisodes.count,
            chapterCount: chapters.count,
            hasAudioTracks: !player.audioTracks.isEmpty,
            hasSubtitles: !subtitleStreams.isEmpty || supportsSubtitleSearch,
            hasQualityChoice: supportsQualityChoice,
            isPiPAvailable: isPiPAvailable)
    }

    /// The live order for the current session, gated exactly as LiveTransportBar renders.
    var liveTransportFocusOrder: [ControlsFocus] {
        Self.liveTransportFocusOrder(
            controls: preferences.playerControls.visibleControls(in: .live),
            isAtLiveEdge: isAtLiveEdge,
            hasAudioTracks: !displayAudioTracks.isEmpty,
            hasSubtitles: !displaySubtitleStreams.isEmpty,
            isPiPAvailable: isPiPAvailable,
            offersMultiview: offersMultiview)
    }
}
