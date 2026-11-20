import Testing
@testable import Sodalite

/// Sodalite#223: which state the per-video Enhanced Upscaling chip shows, if any.
@Suite("Upscale toggle state")
struct UpscaleToggleStateTests {
    private func state(isUpscaling: Bool = false, stageDisabled: Bool = false,
                       override: Bool? = nil) -> PlayerViewModel.UpscaleToggleState? {
        PlayerViewModel.upscaleToggleState(
            isUpscaling: isUpscaling, stageDisabled: stageDisabled, override: override)
    }

    @Test("no chip while the session was never upscaled")
    func absentWithoutStage() {
        #expect(state() == nil)
    }

    @Test("a running stage shows on")
    func running() {
        #expect(state(isUpscaling: true) == .on)
    }

    @Test("the viewer's off wins over whatever the engine still publishes")
    func viewerOff() {
        #expect(state(override: false) == .off)
        #expect(state(isUpscaling: true, override: false) == .off)
    }

    @Test("a stage that switched itself off offers nothing to undo")
    func stageDisabled() {
        #expect(state(isUpscaling: true, stageDisabled: true) == nil)
        #expect(state(isUpscaling: true, stageDisabled: true, override: true) == nil)
    }

    @Test("turned back on, the chip stays up before the first upscaled frame")
    func pendingOn() {
        #expect(state(override: true) == .on)
    }
}
