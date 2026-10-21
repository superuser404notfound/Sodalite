import Testing
@testable import Sodalite

@Suite("Transport focus order")
@MainActor
struct TransportFocusOrderTests {
    private func order(hasSkippableSegment: Bool = false, hasNextEpisodePrompt: Bool = false,
                       episodeCount: Int = 1, chapterCount: Int = 0,
                       hasAudioTracks: Bool = true, hasSubtitles: Bool = true,
                       hasQualityChoice: Bool = false,
                       isPiPAvailable: Bool = false, showsStats: Bool = false,
                       controls: [PlayerControl]? = nil) -> [PlayerViewModel.ControlsFocus] {
        PlayerViewModel.transportFocusOrder(
            controls: controls ?? PlayerControlsLayout.defaults(showsStats: showsStats).visibleControls(in: .transport),
            hasSkippableSegment: hasSkippableSegment, hasNextEpisodePrompt: hasNextEpisodePrompt,
            episodeCount: episodeCount, chapterCount: chapterCount,
            hasAudioTracks: hasAudioTracks, hasSubtitles: hasSubtitles,
            hasQualityChoice: hasQualityChoice,
            isPiPAvailable: isPiPAvailable)
    }

    /// Sodalite#87: the rung sits with the stream choices, after subtitles and before speed.
    @Test("the quality button follows subtitles")
    func qualityPosition() {
        #expect(order(hasQualityChoice: true)
                == [.restartButton, .audioButton, .subtitleButton, .qualityButton, .speedButton, .pictureButton])
    }

    @Test("by default restart leads the arranged part and needs no data")
    func restartLeadsByDefault() {
        #expect(order().first == .restartButton)
        #expect(order(episodeCount: 12, isPiPAvailable: true, showsStats: true).first == .restartButton)
        #expect(order(hasAudioTracks: false, hasSubtitles: false).first == .restartButton)
    }

    /// Sodalite#194: the prompts are not in the viewer's list and lead the row, ahead of it.
    @Test("the skip button leads, ahead of restart")
    func skipSegmentPosition() {
        #expect(order(hasSkippableSegment: true) == [.skipSegmentButton, .restartButton, .audioButton, .subtitleButton, .speedButton, .pictureButton])
    }

    /// Sodalite#103: with the transport open the floating prompt is suppressed and this button is
    /// the only thing that can take the press, so its gate has to match the one the pill draws on.
    @Test("the next-episode button sits beside the skip button, and only while the prompt is up")
    func nextEpisodePosition() {
        #expect(order(hasNextEpisodePrompt: true)
                == [.nextEpisodeButton, .restartButton, .audioButton, .subtitleButton, .speedButton, .pictureButton])
        #expect(order(hasSkippableSegment: true, hasNextEpisodePrompt: true)
                == [.skipSegmentButton, .nextEpisodeButton, .restartButton, .audioButton, .subtitleButton, .speedButton, .pictureButton])
        #expect(!order().contains(.nextEpisodeButton))
    }

    @Test("a bare stream still has restart, speed and picture")
    func minimalOrder() {
        #expect(order(hasAudioTracks: false, hasSubtitles: false) == [.restartButton, .speedButton, .pictureButton])
    }

    /// The chapter button used to be suppressed whenever the item was a series episode, so a remux
    /// with real named chapters lost its only chapter navigation. Each picker now answers for its
    /// own data alone, and the two can stand side by side.
    @Test("chapters and episodes are gated independently and can coexist")
    func chapterGate() {
        #expect(order(episodeCount: 12, chapterCount: 40).contains(.chapterButton))
        #expect(order(episodeCount: 12, chapterCount: 40).contains(.episodeButton))
        #expect(order(episodeCount: 1, chapterCount: 40).contains(.chapterButton))
        #expect(order(episodeCount: 12, chapterCount: 0).contains(.chapterButton) == false)
        #expect(order(episodeCount: 1, chapterCount: 40).contains(.episodeButton) == false)
    }

    @Test("the episode picker precedes the chapter picker when both are present")
    func episodePrecedesChapter() {
        let both = order(episodeCount: 12, chapterCount: 40)
        #expect(both == [.restartButton, .episodeButton, .chapterButton, .audioButton, .subtitleButton, .speedButton, .pictureButton])
    }

    /// Up from the scrub bar lands on the leftmost control that is not "From Start"; reading it off
    /// the same order the bar renders from is what keeps that landing on a button that exists.
    @Test("the up-from-scrub-bar landing is the leftmost control that is not restart")
    func upFromProgressBarLanding() {
        #expect(PlayerViewModel.upLanding(in: order(episodeCount: 12, chapterCount: 40)) == .episodeButton)
        #expect(PlayerViewModel.upLanding(in: order(episodeCount: 1, chapterCount: 40)) == .chapterButton)
        #expect(PlayerViewModel.upLanding(in: order(hasSkippableSegment: true, episodeCount: 12, chapterCount: 40)) == .skipSegmentButton)
        #expect(PlayerViewModel.upLanding(in: order(hasAudioTracks: false, hasSubtitles: false)) == .speedButton)
    }

    /// Sodalite#194: Up used to fall back to Speed, which the viewer can now hide.
    @Test("with only restart left Up lands on it, with nothing left it stays on the bar")
    func upLandingEdges() {
        #expect(PlayerViewModel.upLanding(in: order(controls: [.restart])) == .restartButton)
        #expect(PlayerViewModel.upLanding(in: order(controls: [])) == nil)
        #expect(PlayerViewModel.upLanding(in: order(hasSkippableSegment: true, controls: [])) == .skipSegmentButton)
    }

    @Test("the viewer's arrangement sets the order and hides what it leaves out")
    func arrangement() {
        #expect(order(chapterCount: 40, showsStats: true, controls: [.stats, .chapters, .subtitles, .audio])
                == [.infoButton, .chapterButton, .subtitleButton, .audioButton])
        #expect(order(hasNextEpisodePrompt: true, controls: [.speed])
                == [.nextEpisodeButton, .speedButton])
    }

    @Test("an arranged control still needs its data")
    func arrangedControlKeepsItsGate() {
        #expect(order(chapterCount: 0, controls: [.chapters, .pip, .quality]).isEmpty)
    }

    @Test("optional trailing buttons appear only when enabled")
    func trailingButtons() {
        #expect(order().contains(.pipButton) == false)
        #expect(order().contains(.infoButton) == false)
        #expect(Array(order(isPiPAvailable: true, showsStats: true).suffix(2)) == [.pipButton, .infoButton])
    }
}

@Suite("Live transport focus order")
@MainActor
struct LiveTransportFocusOrderTests {
    private func order(isAtLiveEdge: Bool = true, hasAudioTracks: Bool = false,
                       hasSubtitles: Bool = false, isPiPAvailable: Bool = false,
                       offersMultiview: Bool = false,
                       showsStats: Bool = false,
                       controls: [PlayerControl]? = nil) -> [PlayerViewModel.ControlsFocus] {
        PlayerViewModel.liveTransportFocusOrder(
            controls: controls ?? PlayerControlsLayout.defaults(showsStats: showsStats).visibleControls(in: .live),
            isAtLiveEdge: isAtLiveEdge, hasAudioTracks: hasAudioTracks,
            hasSubtitles: hasSubtitles, isPiPAvailable: isPiPAvailable,
            offersMultiview: offersMultiview)
    }

    /// Sodalite#194: Return to Live is the live prompt and stays ahead of any arrangement.
    @Test("the viewer's arrangement orders the live row behind Return to Live")
    func liveArrangement() {
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true, hasSubtitles: true, showsStats: true,
                      controls: [.stats, .subtitles])
                == [.returnToLiveButton, .infoButton, .subtitleButton])
    }

    @Test("the multiview button sits after PiP and before stats, and only when offered")
    func multiviewInLiveOrder() {
        #expect(order(hasAudioTracks: true, isPiPAvailable: true, offersMultiview: true, showsStats: true)
            == [.audioButton, .pipButton, .multiviewButton, .infoButton])
        #expect(!order(hasAudioTracks: true, isPiPAvailable: true, showsStats: true).contains(.multiviewButton))
    }

    @Test("a channel at the live edge with nothing to pick has no controls above the scrubber")
    func emptyAtEdge() {
        #expect(order().isEmpty)
    }

    @Test("Return to Live exists only while behind the edge, and leads")
    func returnToLiveGate() {
        #expect(order(isAtLiveEdge: false) == [.returnToLiveButton])
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true).first == .returnToLiveButton)
        #expect(order(isAtLiveEdge: true, hasAudioTracks: true).contains(.returnToLiveButton) == false)
    }

    @Test("audio precedes subtitles, as in the VOD bar")
    func trackOrderMatchesVOD() {
        #expect(order(hasAudioTracks: true, hasSubtitles: true) == [.audioButton, .subtitleButton])
    }

    @Test("each control is gated on its own list, none on another's")
    func independentGates() {
        #expect(order(hasAudioTracks: true) == [.audioButton])
        #expect(order(hasSubtitles: true) == [.subtitleButton])
        #expect(order(isPiPAvailable: true) == [.pipButton])
    }

    @Test("PiP stays last so the track pickers keep their place as a channel gains tracks")
    func pipTrails() {
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true, hasSubtitles: true, isPiPAvailable: true)
                == [.returnToLiveButton, .audioButton, .subtitleButton, .pipButton])
    }

    /// The live bar had no info chip at all, so the stats panel was unreachable on tvOS for the one kind of
    /// session whose route and tuner it is worth reading. It sits last, as in the VOD order.
    @Test("the stats chip follows the preference, and trails")
    func statsChipGate() {
        #expect(order(showsStats: true) == [.infoButton])
        #expect(order().contains(.infoButton) == false)
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true, hasSubtitles: true,
                      isPiPAvailable: true, showsStats: true)
                == [.returnToLiveButton, .audioButton, .subtitleButton, .pipButton, .infoButton])
    }
}
