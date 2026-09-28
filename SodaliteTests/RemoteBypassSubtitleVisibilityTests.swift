import AetherEngine
import Testing
@testable import Sodalite

/// Sodalite#87: on the remote-HLS bypass a transcode plays on, the engine hands subtitles to AVPlayer as
/// injected renditions and publishes no cues for an overlay (AE#316, by design). Styling the rendition
/// invisible there, as fullscreen does on every other route, left an empty caption box on screen.
struct RemoteBypassSubtitleVisibilityTests {
    @Test func theBypassAlwaysShowsTheRenditionsText() {
        #expect(PlayerViewModel.renditionShowsText(requested: false, route: .remoteBypass))
        #expect(PlayerViewModel.renditionShowsText(requested: true, route: .remoteBypass))
    }

    @Test func otherRoutesFollowTheRequest() {
        #expect(!PlayerViewModel.renditionShowsText(requested: false, route: .loopback))
        #expect(!PlayerViewModel.renditionShowsText(requested: false, route: .software))
        #expect(PlayerViewModel.renditionShowsText(requested: true, route: .loopback))
    }
}
