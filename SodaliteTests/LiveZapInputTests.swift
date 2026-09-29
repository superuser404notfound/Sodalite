import Testing
@testable import Sodalite

struct LiveZapInputTests {
    private func act(_ key: LiveZapInput.Key, live: Bool = true, controls: Bool = false,
                     error: Bool = false, overlay: Bool = false) -> LiveZapInput.Action {
        LiveZapInput.action(for: key, isLive: live, showControls: controls,
                            errorVisible: error, overlayCapturesInput: overlay)
    }

    @Test func hiddenControlsZap() {
        #expect(act(.up) == .zap(1))
        #expect(act(.down) == .zap(-1))
    }
    @Test func visibleControlsKeepTheBar() {
        #expect(act(.up, controls: true) == .passThrough)
        #expect(act(.down, controls: true) == .passThrough)
    }
    @Test func pageKeysZapEvenOverTheBar() {
        #expect(act(.pageUp, controls: true) == .zap(1))
        #expect(act(.pageDown, controls: true) == .zap(-1))
    }
    @Test func anErrorScreenStillZaps() {
        #expect(act(.up, controls: true, error: true) == .zap(1))
    }
    @Test func anOpenOverlayKeepsItsKeys() {
        #expect(act(.up, overlay: true) == .passThrough)
        #expect(act(.pageUp, overlay: true) == .ignore)
    }
    @Test func vodIsUnchanged() {
        #expect(act(.up, live: false) == .passThrough)
        #expect(act(.pageDown, live: false) == .ignore)
    }
}
