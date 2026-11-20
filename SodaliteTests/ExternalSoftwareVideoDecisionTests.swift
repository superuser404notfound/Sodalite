import AetherEngine
import Testing

@testable import Sodalite

@Suite("External software video decision (Sodalite#189)")
struct ExternalSoftwareVideoDecisionTests {
    @Test("moves the software picture to an attached display", arguments: [PlaybackBackend.software, .aether])
    func softwarePathTakesTheScreen(backend: PlaybackBackend) {
        #expect(ExternalSoftwareVideoDecision.shouldOwnExternalScreen(backend: backend, externalScenePresent: true))
        #expect(!ExternalSoftwareVideoDecision.shouldOwnExternalScreen(backend: backend, externalScenePresent: false))
    }

    @Test("leaves the native path to AVKit, and a session with no picture alone",
          arguments: [PlaybackBackend.native, .audio, .none])
    func otherBackendsStandDown(backend: PlaybackBackend) {
        #expect(!ExternalSoftwareVideoDecision.shouldOwnExternalScreen(backend: backend, externalScenePresent: true))
    }
}
