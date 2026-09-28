import Foundation
import Testing
@testable import Sodalite

/// Findings of the whole-branch review of Sodalite#81, each pinned before its fix.
@MainActor
struct DownloadReviewFixTests {
    private let profile = ProfileKey(serverID: "srv", userID: "usr")

    private func make(backend: FakeDownloadBackend = FakeDownloadBackend(),
                      transport: FakeDownloadTransport = FakeDownloadTransport()) -> (DownloadManager, DownloadStore, FakeDownloadTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DRF-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(profile)
        return (DownloadManager(store: store, backend: backend, transport: transport), store, transport, root)
    }

    private func movie(_ id: String) -> JellyfinItem {
        try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"M","Type":"Movie","RunTimeTicks":36000000000}"#.utf8))
    }

    private func moveIn(_ store: DownloadStore, _ tag: DownloadTaskTag) throws -> URL {
        let dir = store.paths.itemDirectory(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID)
        let file = dir.appendingPathComponent("media.\(tag.fileExtension)")
        try Data(count: 10).write(to: file)
        return file
    }

    // C1: iOS relaunches the app in the background, no scene, so no profile is active.
    @Test func aFinishWhileNoProfileIsActiveLandsOnDisk() async throws {
        let (manager, store, transport, _) = make()
        try await manager.enqueue(item: movie("a"), quality: .original)
        let tag = transport.started[0].tag
        store.activate(nil)
        await manager.handle(event: .finished(tag, status: 200, movedTo: try moveIn(store, tag)))
        store.activate(profile)
        #expect(store.item("a")?.manifest.state == .complete)
        let before = transport.started.count
        await manager.reattach()
        #expect(transport.started.count == before)
    }

    @Test func reattachCompletesAnOrphanWhoseFileArrived() async throws {
        let (manager, store, transport, _) = make()
        try await manager.enqueue(item: movie("a"), quality: .original)
        let tag = transport.started[0].tag
        _ = try moveIn(store, tag)
        transport.live = [:]
        await manager.reattach()
        #expect(store.item("a")?.manifest.state == .complete)
        #expect(store.item("a")?.manifest.mediaFileName == "media.mkv")
        #expect(transport.started.count == 1)
    }

    @Test func aFinishForAnotherProfileLeavesTheActiveOneAlone() async throws {
        let (manager, store, transport, _) = make()
        try await manager.enqueue(item: movie("a"), quality: .original)
        let tagA = transport.started[0].tag
        store.activate(ProfileKey(serverID: "srv", userID: "kid"))
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .finished(tagA, status: 200, movedTo: try moveIn(store, tagA)))
        #expect(store.item("a")?.manifest.state == .downloading)
        store.activate(profile)
        #expect(store.item("a")?.manifest.state == .complete)
    }

    // I3
    @Test func resumeDataIsConsumedOnceAndDroppedAfterAnHTTPFailure() async throws {
        let (manager, _, transport, _) = make()
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .failed(transport.started[0].tag, resumeData: Data([1]), cancelled: false))
        manager.retry(itemID: "a")
        #expect(transport.started.last?.resumeData == Data([1]))
        await manager.handle(event: .finished(transport.started.last!.tag, status: 401, movedTo: nil))
        manager.retry(itemID: "a")
        #expect(transport.started.last?.resumeData == nil)
    }

    @Test func aChangedNetworkPolicyRestartsRunningDownloads() async throws {
        let backend = FakeDownloadBackend()
        let (manager, _, transport, _) = make(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .original)
        #expect(transport.started.last?.allowsCellular == false)
        backend.allowsCellular = true
        await manager.applyNetworkPolicy()
        #expect(transport.started.last?.allowsCellular == true)
        #expect(transport.started.count == 2)
    }

    // I5
    @Test func purgingAnotherProfileCancelsItsTasks() async throws {
        let (manager, store, transport, _) = make()
        try await manager.enqueue(item: movie("a"), quality: .original)
        store.activate(ProfileKey(serverID: "srv", userID: "kid"))
        await DownloadCleanup.perform(.profile(serverID: "srv", userID: "usr"), store: store, manager: manager)
        #expect(transport.live.isEmpty)
    }

    // I8
    @Test func aTruncatedTranscodeFails() async throws {
        let backend = FakeDownloadBackend()
        backend.sourceBitrate = 30_000_000
        backend.transcodingUrl = "/videos/a/stream.mp4"
        backend.probedDuration = 600
        let (manager, store, transport, _) = make(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .mbps4)
        let tag = transport.started[0].tag
        await manager.handle(event: .finished(tag, status: 200, movedTo: try moveIn(store, tag)))
        #expect(store.item("a")?.manifest.state == .failed)
        #expect(store.item("a")?.manifest.failure == .server)
    }

    @Test func aWholeTranscodeCompletes() async throws {
        let backend = FakeDownloadBackend()
        backend.sourceBitrate = 30_000_000
        backend.transcodingUrl = "/videos/a/stream.mp4"
        backend.probedDuration = 3590
        let (manager, store, transport, _) = make(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .mbps4)
        let tag = transport.started[0].tag
        await manager.handle(event: .finished(tag, status: 200, movedTo: try moveIn(store, tag)))
        #expect(store.item("a")?.manifest.state == .complete)
    }

    // 9
    @Test func aDoubleTapStartsOneTask() async throws {
        let backend = FakeDownloadBackend()
        backend.yieldsInPlaybackInfo = true
        let (manager, _, transport, _) = make(backend: backend)
        async let first: Void = manager.enqueue(item: movie("a"), quality: .original)
        async let second: Void = manager.enqueue(item: movie("a"), quality: .original)
        _ = try await (first, second)
        #expect(transport.started.count == 1)
    }
}
