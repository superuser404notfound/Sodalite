import Foundation
import Testing
@testable import Sodalite

#if os(tvOS)
/// Sodalite#167: a thumb resting on the clickpad raises the transport the way Up does from hidden,
/// and only where that cannot change what the next click or swipe means.
@Suite("Siri Remote resting touch")
struct SiriRemoteRestingTouchTests {
    @Test("a rest on hidden controls reveals the transport")
    func hiddenReveals() {
        #expect(SiriRemoteRestingTouch.revealsTransport(
            showControls: false, overlayCapturesInput: false, nextEpisodePromptVisible: false))
    }

    @Test("a rest on visible controls does nothing")
    func visibleIsInert() {
        #expect(!SiriRemoteRestingTouch.revealsTransport(
            showControls: true, overlayCapturesInput: false, nextEpisodePromptVisible: false))
    }

    /// The prompt owns Select only while the transport is hidden, so a reveal under a resting thumb
    /// would turn the click that plays the next episode into a pause.
    @Test("the next-episode prompt keeps the click")
    func nextEpisodeKeepsClick() {
        #expect(!SiriRemoteRestingTouch.revealsTransport(
            showControls: false, overlayCapturesInput: false, nextEpisodePromptVisible: true))
    }

    @Test("an overlay that owns the remote keeps it")
    func overlayKeepsRemote() {
        #expect(!SiriRemoteRestingTouch.revealsTransport(
            showControls: false, overlayCapturesInput: true, nextEpisodePromptVisible: false))
    }

    /// A click has to land inside the dwell and a swipe has to leave it by moving, or the rest changes
    /// what they mean. Pinned so a retune is a deliberate edit.
    @Test("dwell and slop sit where the constants say")
    func thresholds() {
        #expect(SiriRemoteRestingTouch.dwell == 0.35)
        #expect(SiriRemoteRestingTouch.slop == 40)
    }
}
#endif
