import Testing
@testable import Sodalite

struct PlayerPresentationModeTests {
    @Test("a fresh player launches, stops on dismiss and owns the lifecycle")
    func standalone() {
        let m = PlayerPresentationMode.standalone
        #expect(m.launchesPlayback && m.stopsOnDismiss && m.observesAppLifecycle && m.offersPictureInPicture && m.offersMultiview)
    }

    @Test("the survivor after multiview does not reload but is otherwise a normal player")
    func continuing() {
        let m = PlayerPresentationMode.continuing
        #expect(!m.launchesPlayback)
        #expect(m.stopsOnDismiss && m.observesAppLifecycle && m.offersPictureInPicture && m.offersMultiview)
    }

    @Test("a tile's full screen neither reloads nor stops, and leaves lifecycle to the session")
    func multiviewTile() {
        let m = PlayerPresentationMode.multiviewTile
        #expect(!m.launchesPlayback && !m.stopsOnDismiss && !m.observesAppLifecycle)
        #expect(!m.offersPictureInPicture && !m.offersMultiview)
    }
}
