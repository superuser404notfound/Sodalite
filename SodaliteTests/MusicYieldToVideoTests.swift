import Testing
import Foundation
@testable import Sodalite

/// A video load that fails before the engine picks a backend used to leave a dead music queue that
/// swallowed every Play button. The players announce the takeover before the load instead.
/// Audit 2026-11-17 LTM-202.
@MainActor
struct MusicYieldToVideoTests {

    private func track(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Audio"}"#.utf8))
    }

    @Test func yieldingClearsTheQueueWithoutWaitingForAVideoBackend() async throws {
        let service = RecordingPlaybackService()
        service.hangingItemIDs = ["A"]
        let coordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userIDProvider: { "user" })
        coordinator.play(queue: [try track("A"), try track("B")], startAt: 0)
        #expect(coordinator.currentItem?.id == "A")

        coordinator.yieldToVideo()

        #expect(coordinator.queue.isEmpty)
        #expect(coordinator.currentItem == nil)
        #expect(coordinator.isPlaying == false)
    }

    @Test func yieldingWithNothingQueuedDoesNothing() {
        let coordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: RecordingPlaybackService(),
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userIDProvider: { "user" })
        coordinator.yieldToVideo()
        #expect(coordinator.queue.isEmpty)
    }
}
