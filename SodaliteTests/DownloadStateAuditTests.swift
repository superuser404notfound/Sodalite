import Foundation
import Testing
@testable import Sodalite

/// Audit ASD-202, 206, 207 and 208 on the download manager and its transport.
@MainActor
struct DownloadStateAuditTests {
    private let profile = ProfileKey(serverID: "srv", userID: "usr")

    private func makeManager(backend: FakeDownloadBackend = FakeDownloadBackend()) -> (DownloadManager, DownloadStore, FakeDownloadTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DSA-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(profile)
        let transport = FakeDownloadTransport()
        return (DownloadManager(store: store, backend: backend, transport: transport), store, transport)
    }

    private func movie(_ id: String) -> JellyfinItem {
        try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"M","Type":"Movie","RunTimeTicks":36000000000}"#.utf8))
    }

    private func manifest(_ id: String, state: DownloadState, expected: Int64, received: Int64 = 0) -> DownloadManifest {
        var m = DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                 mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil, state: state, createdAt: Date())
        m.expectedBytes = expected
        m.receivedBytes = received
        return m
    }

    @Test func aRunningDownloadReservesOnlyWhatIsStillToCome() {
        let running = manifest("a", state: .downloading, expected: 3_000)
        let queued = manifest("b", state: .queued, expected: 1_000)
        #expect(DownloadManager.reservedBytes([running, queued], liveProgress: ["a": 0.9]) == 300 + 1_000)
        #expect(DownloadManager.reservedBytes([running], liveProgress: [:]) == 3_000)
    }

    @Test func aFullDiskDuringTheDownloadIsNoSpaceNotANetworkError() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .failed(transport.started[0].tag, resumeData: nil, cancelled: false, diskFull: true))
        #expect(store.item("a")?.manifest.failure == .noSpace)
    }

    @Test func diskFullIsRecognisedThroughTheUnderlyingError() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(DownloadPlanner.isDiskFull(wrapped))
        #expect(DownloadPlanner.isDiskFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(!DownloadPlanner.isDiskFull(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    @Test func aTaskThatIsBeingCancelledIsNotTheLiveOne() {
        let task = URLSession.shared.downloadTask(with: URL(string: "https://jf.example/x")!)
        #expect(BackgroundDownloadTransport.isLive(task))
        task.cancel()
        #expect(!BackgroundDownloadTransport.isLive(task))
    }

    @Test func aFinishedFileThatCouldNotBeMovedFailsTheItem() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .finished(transport.started[0].tag, status: 200, movedTo: nil))
        #expect(store.item("a")?.manifest.state == .failed)
        #expect(store.item("a")?.manifest.failure == .server)
    }

    @Test func retryOfARefusedTranscodeAsksPlaybackInfoAgain() async throws {
        let backend = FakeDownloadBackend()
        backend.sourceBitrate = 30_000_000
        backend.transcodingUrl = "/videos/a/stream.mp4?PlaySessionId=old&api_key=T"
        let (manager, store, transport) = makeManager(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .mbps4)
        await manager.handle(event: .finished(transport.started[0].tag, status: 404, movedTo: nil))
        #expect(store.item("a")?.manifest.transcodeURL?.contains("old") == true)

        backend.transcodingUrl = "/videos/a/stream.mp4?PlaySessionId=fresh&api_key=T"
        await manager.refreshTranscode(itemID: "a")
        #expect(store.item("a")?.manifest.transcodeURL?.contains("fresh") == true)
        #expect(store.item("a")?.manifest.playSessionID == "ps-a")
    }
}
