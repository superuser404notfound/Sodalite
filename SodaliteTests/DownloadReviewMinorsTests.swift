import Foundation
import Testing
@testable import Sodalite

/// The review minors of Sodalite#81 that were deferred and are now fixed.
@MainActor
struct DownloadReviewMinorsTests {
    private let profile = ProfileKey(serverID: "srv", userID: "usr")

    private func make(backend: FakeDownloadBackend = FakeDownloadBackend()) -> (DownloadManager, DownloadStore, FakeDownloadTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DRM-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(profile)
        let transport = FakeDownloadTransport()
        return (DownloadManager(store: store, backend: backend, transport: transport), store, transport)
    }

    private func movie(_ id: String) -> JellyfinItem {
        try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"M","Type":"Movie","RunTimeTicks":36000000000}"#.utf8))
    }

    /// #11: iOS cancels background tasks when the viewer force-quits; that is an interruption to
    /// resume from, not the viewer's own cancel, and not a failure to retry by hand.
    @Test func aForceQuitResumesWhereItStopped() async throws {
        let (manager, store, transport) = make()
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .interrupted(transport.started[0].tag, resumeData: Data([7])))
        #expect(store.item("a")?.manifest.state == .downloading)
        #expect(transport.started.count == 2)
        #expect(transport.started.last?.resumeData == Data([7]))
    }

    /// #12: the space check counts what is already queued, so a season cannot overcommit the disk.
    @Test func queuedDownloadsReserveTheirSpace() async throws {
        let backend = FakeDownloadBackend()
        backend.available = DownloadPlanner.spaceHeadroom + 1500
        let (manager, _, _) = make(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .original)
        await #expect(throws: DownloadEnqueueError.noSpace) {
            try await manager.enqueue(item: movie("b"), quality: .original)
        }
    }

    /// #12: one episode the server will not hand out must not cost the rest of the season.
    @Test func aSeasonSkipsAnEpisodeThatFails() async throws {
        let backend = FakeDownloadBackend()
        backend.seasonEpisodes = ["e1", "e2", "e3"]
        backend.failingItemIDs = ["e2"]
        let (manager, store, _) = make(backend: backend)
        await #expect(throws: (any Error).self) {
            try await manager.enqueueSeason(seriesID: "s", seasonID: "se", quality: .original)
        }
        #expect(Set(store.items.keys) == ["e1", "e3"])
    }
}
