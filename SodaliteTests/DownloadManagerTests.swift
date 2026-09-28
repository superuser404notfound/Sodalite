import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadManagerTests {
    private let profile = ProfileKey(serverID: "srv", userID: "usr")

    private func makeManager(backend: FakeDownloadBackend = FakeDownloadBackend(),
                             transport: FakeDownloadTransport = FakeDownloadTransport()) -> (DownloadManager, DownloadStore, FakeDownloadTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DM-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(profile)
        let manager = DownloadManager(store: store, backend: backend, transport: transport)
        return (manager, store, transport)
    }

    private func movie(_ id: String) -> JellyfinItem {
        try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"M","Type":"Movie","RunTimeTicks":36000000000}"#.utf8))
    }

    @Test func enqueueStoresTheSnapshotAndStartsTheTask() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        #expect(store.item("a")?.manifest.state == .downloading)
        #expect(store.item("a")?.manifest.route == .original)
        #expect(transport.started.map(\.tag.itemID) == ["a"])
        #expect(transport.started.first?.request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"T\"")
        #expect(transport.started.first?.request.url?.query == nil)
    }

    @Test func enqueueRefusesWithoutSpace() async {
        let backend = FakeDownloadBackend()
        backend.available = 10
        let (manager, store, transport) = makeManager(backend: backend)
        await #expect(throws: DownloadEnqueueError.noSpace) {
            try await manager.enqueue(item: movie("a"), quality: .original)
        }
        #expect(store.item("a") == nil)
        #expect(transport.started.isEmpty)
    }

    @Test func aThirdOriginalWaits() async throws {
        let (manager, store, transport) = makeManager()
        for id in ["a", "b", "c"] { try await manager.enqueue(item: movie(id), quality: .original) }
        #expect(transport.started.count == 2)
        #expect(store.item("c")?.manifest.state == .queued)
    }

    @Test func finishingMovesTheFileAndStartsTheNext() async throws {
        let (manager, store, transport) = makeManager()
        for id in ["a", "b", "c"] { try await manager.enqueue(item: movie(id), quality: .original) }
        let tag = transport.started[0].tag
        let dir = store.item("a")!.directory
        let moved = dir.appendingPathComponent("media.mkv")
        try Data(count: 10).write(to: moved)
        await manager.handle(event: .finished(tag, status: 200, movedTo: moved))
        #expect(store.item("a")?.manifest.state == .complete)
        #expect(store.item("a")?.manifest.mediaFileName == "media.mkv")
        #expect(store.completedItem("a") != nil)
        #expect(transport.started.map(\.tag.itemID) == ["a", "b", "c"])
    }

    @Test func finishWithForbiddenMarksNotAllowed() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .finished(transport.started[0].tag, status: 403, movedTo: nil))
        #expect(store.item("a")?.manifest.state == .failed)
        #expect(store.item("a")?.manifest.failure == .notAllowed)
    }

    @Test func aNetworkFailureKeepsResumeDataForOriginals() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .failed(transport.started[0].tag, resumeData: Data([1, 2, 3]), cancelled: false))
        #expect(store.item("a")?.manifest.state == .failed)
        #expect(store.item("a")?.manifest.failure == .network)
        manager.retry(itemID: "a")
        #expect(transport.started.last?.resumeData == Data([1, 2, 3]))
    }

    @Test func pauseAndResume() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        transport.resumeDataOnCancel = Data([9])
        await manager.pause(itemID: "a")
        #expect(store.item("a")?.manifest.state == .paused)
        manager.resume(itemID: "a")
        #expect(store.item("a")?.manifest.state == .downloading)
        #expect(transport.started.last?.resumeData == Data([9]))
    }

    @Test func aTranscodeRestartsFromZeroAndKillsItsEncodeOnCancel() async throws {
        let backend = FakeDownloadBackend()
        backend.sourceBitrate = 30_000_000
        backend.transcodingUrl = "/videos/a/stream.mp4?MediaSourceId=src&api_key=T"
        let (manager, store, transport) = makeManager(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .mbps4)
        #expect(store.item("a")?.manifest.route == .transcode)
        await manager.handle(event: .failed(transport.started[0].tag, resumeData: Data([1]), cancelled: false))
        manager.retry(itemID: "a")
        #expect(transport.started.last?.resumeData == nil)
        await manager.cancel(itemID: "a")
        #expect(backend.killedSessions == ["ps-a"])
        #expect(store.item("a") == nil)
    }

    @Test func unauthorizedRetryRebuildsTheRequest() async throws {
        let backend = FakeDownloadBackend()
        let (manager, store, transport) = makeManager(backend: backend)
        try await manager.enqueue(item: movie("a"), quality: .original)
        await manager.handle(event: .finished(transport.started[0].tag, status: 401, movedTo: nil))
        #expect(store.item("a")?.manifest.failure == .unauthorized)
        backend.authorization = "MediaBrowser Token=\"NEW\""
        manager.retry(itemID: "a")
        #expect(transport.started.last?.request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"NEW\"")
    }

    @Test func reattachRequeuesOrphans() async throws {
        let (manager, store, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        transport.live = [:]
        let before = transport.started.count
        await manager.reattach()
        // orphaned "downloading" went back to the queue and was started again
        #expect(transport.started.count == before + 1)
        #expect(store.item("a")?.manifest.state == .downloading)
    }

    @Test func reattachKeepsLiveTasks() async throws {
        let (manager, _, transport) = makeManager()
        try await manager.enqueue(item: movie("a"), quality: .original)
        let before = transport.started.count
        await manager.reattach()
        #expect(transport.started.count == before)
    }

    @Test func enqueueSeasonAddsEveryEpisodeOnce() async throws {
        let backend = FakeDownloadBackend()
        backend.seasonEpisodes = ["e1", "e2", "e3"]
        let (manager, store, _) = makeManager(backend: backend)
        try await manager.enqueueSeason(seriesID: "s", seasonID: "se", quality: .original)
        try await manager.enqueueSeason(seriesID: "s", seasonID: "se", quality: .original)
        #expect(Set(store.items.keys) == ["e1", "e2", "e3"])
    }
}

@MainActor
final class FakeDownloadBackend: DownloadBackend {
    var available: Int64? = 1_000_000_000_000
    var authorization = "MediaBrowser Token=\"T\""
    var sourceBitrate = 8_000_000
    var transcodingUrl: String?
    var seasonEpisodes: [String] = []
    var killedSessions: [String] = []
    let baseURL: URL? = URL(string: "https://jf.example")
    let userID = "usr"
    let preferredAudioLanguage: String? = nil

    func playbackInfo(itemID: String, profile: [String: Any], mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse {
        let tc = transcodingUrl.map { #","TranscodingUrl":"\#($0)""# } ?? ""
        let json = #"{"PlaySessionId":"ps-\#(itemID)","MediaSources":[{"Id":"src-\#(itemID)","Container":"mkv","Size":1000,"Bitrate":\#(sourceBitrate)\#(tc),"MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"},{"Index":1,"Type":"Audio","Codec":"aac"}]}]}"#
        return try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
    }
    func itemDetail(itemID: String) async throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(itemID)","Name":"x","Type":"Movie","RunTimeTicks":36000000000}"#.utf8))
    }
    func seasonEpisodes(seriesID: String, seasonID: String) async throws -> [JellyfinItem] {
        try seasonEpisodes.map {
            try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#($0)","Name":"e","Type":"Episode","SeriesId":"s","SeasonId":"se","RunTimeTicks":18000000000}"#.utf8))
        }
    }
    func subtitleURL(itemID: String, mediaSourceID: String, stream: MediaStream) -> URL? { nil }
    func artworkURLs(for item: JellyfinItem) -> [DownloadArtwork: URL] { [:] }
    func fetch(_ request: URLRequest) async throws -> Data { Data() }
    func availableCapacity() -> Int64? { available }
    func stopEncoding(playSessionID: String) async { killedSessions.append(playSessionID) }
    var allowsCellular: Bool { false }
}

@MainActor
final class FakeDownloadTransport: DownloadTransport {
    struct Start { let request: URLRequest; let resumeData: Data?; let tag: DownloadTaskTag }
    var started: [Start] = []
    var live: [DownloadTaskTag: Int] = [:]
    var resumeDataOnCancel: Data?
    private var nextID = 1

    func start(request: URLRequest, resumeData: Data?, tag: DownloadTaskTag, allowsCellular: Bool) -> Int {
        started.append(Start(request: request, resumeData: resumeData, tag: tag))
        nextID += 1
        live[tag] = nextID
        return nextID
    }
    func cancel(tag: DownloadTaskTag, producingResumeData: Bool) async -> Data? {
        live[tag] = nil
        return producingResumeData ? resumeDataOnCancel : nil
    }
    func liveTags() async -> Set<DownloadTaskTag> { Set(live.keys) }
}
