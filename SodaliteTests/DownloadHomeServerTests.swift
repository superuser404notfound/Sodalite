import Foundation
import Testing
@testable import Sodalite

/// Sodalite#202 follow-up: downloads from another server of a combined Home, and the system activity's stop.
@MainActor
struct DownloadHomeServerTests {
    private let profile = ProfileKey(serverID: "srv", userID: "usr")

    private func makeManager(secondaries: [String: FakeDownloadBackend]) -> (DownloadManager, DownloadStore, FakeDownloadTransport, Box) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DH-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(profile)
        let transport = FakeDownloadTransport()
        let box = Box(backends: secondaries)
        let manager = DownloadManager(store: store, backend: FakeDownloadBackend(), transport: transport,
                                      secondaryBackend: { box.backends[$0] })
        return (manager, store, transport, box)
    }

    /// Which secondaries take part right now; tests drop and restore them.
    final class Box {
        var backends: [String: FakeDownloadBackend]
        init(backends: [String: FakeDownloadBackend]) { self.backends = backends }
    }

    private func movie(_ id: String, server: String?) -> JellyfinItem {
        let serverField = server.map { #","ServerId":"\#($0)""# } ?? ""
        return try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"M","Type":"Movie","RunTimeTicks":36000000000\#(serverField)}"#.utf8))
    }

    private func secondary() -> FakeDownloadBackend {
        let backend = FakeDownloadBackend()
        backend.authorization = "MediaBrowser Token=\"B\""
        return backend
    }

    @Test func anItemOfAnotherServerDownloadsFromThatServer() async throws {
        let (manager, store, transport, _) = makeManager(secondaries: ["b": secondary()])
        try await manager.enqueue(item: movie("x", server: "b"), quality: .original)
        #expect(store.item("x")?.manifest.originServerID == "b")
        #expect(store.item("x")?.manifest.originUserID == "usr")
        #expect(transport.started.first?.request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"B\"")
        // Stored under the profile that downloaded it, so the Downloads tab lists it.
        #expect(transport.started.first?.tag.serverID == "srv")
    }

    @Test func anItemOfTheActiveServerKeepsNoOrigin() async throws {
        let (manager, store, transport, _) = makeManager(secondaries: ["b": secondary()])
        try await manager.enqueue(item: movie("x", server: "srv"), quality: .original)
        #expect(store.item("x")?.manifest.originServerID == nil)
        #expect(transport.started.first?.request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"T\"")
    }

    @Test func aDownloadWaitsForItsServerWithoutTakingASlot() async throws {
        let (manager, store, transport, box) = makeManager(secondaries: ["b": secondary()])
        try await manager.enqueue(item: movie("x", server: "b"), quality: .original)
        await manager.pause(itemID: "x")
        let held = box.backends.removeValue(forKey: "b")
        manager.resume(itemID: "x")
        #expect(store.item("x")?.manifest.state == .queued)
        try await manager.enqueue(item: movie("y", server: nil), quality: .original)
        try await manager.enqueue(item: movie("z", server: nil), quality: .original)
        #expect(Set(transport.started.suffix(2).map(\.tag.itemID)) == ["y", "z"])

        for tag in transport.started.suffix(2).map(\.tag) {
            let moved = store.item(tag.itemID)!.directory.appendingPathComponent("media.mkv")
            try Data(count: 1).write(to: moved)
            await manager.handle(event: .finished(tag, status: 200, movedTo: moved))
        }
        #expect(store.item("x")?.manifest.state == .queued)
        box.backends["b"] = held
        manager.serversChanged()
        #expect(store.item("x")?.manifest.state == .downloading)
    }

    @Test func stoppingTheActivityPausesInsteadOfDeleting() async throws {
        let (manager, store, _, _) = makeManager(secondaries: [:])
        for id in ["a", "b", "c"] { try await manager.enqueue(item: movie(id, server: nil), quality: .original) }
        await manager.pause(itemIDs: ["a", "b", "c"])
        #expect(["a", "b", "c"].allSatisfy { store.item($0)?.manifest.state == .paused })
    }

    @Test func removingAServerTakesWhatTheHomeFetchedFromIt() async throws {
        let (manager, store, _, _) = makeManager(secondaries: ["b": secondary()])
        try await manager.enqueue(item: movie("x", server: "b"), quality: .original)
        try await manager.enqueue(item: movie("y", server: nil), quality: .original)
        let directory = store.item("x")!.directory
        #expect(DownloadCleanup.usage(.server("b"), store: store).items == 1)
        await DownloadCleanup.perform(.server("b"), store: store, manager: manager)
        #expect(store.item("x") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.item("y") != nil)
    }

    @Test func anItemOfAServerNotTakingPartIsRefusedNotAskedOfTheActiveOne() async {
        let (manager, store, transport, _) = makeManager(secondaries: [:])
        await #expect(throws: DownloadEnqueueError.noServer) {
            try await manager.enqueue(item: movie("x", server: "b"), quality: .original)
        }
        #expect(store.item("x") == nil)
        #expect(transport.started.isEmpty)
    }

    @Test func aServerSignedInAsSomeoneElseLeavesTheDownloadWaiting() async throws {
        let (manager, store, _, box) = makeManager(secondaries: ["b": secondary()])
        try await manager.enqueue(item: movie("x", server: "b"), quality: .original)
        await manager.pause(itemID: "x")
        let other = secondary()
        other.userIDOverride = "someone-else"
        box.backends["b"] = other
        manager.resume(itemID: "x")
        #expect(store.item("x")?.manifest.state == .queued)
    }

    @Test func pausingABatchStartsNothingOfIt() async throws {
        let (manager, store, transport, _) = makeManager(secondaries: [:])
        for id in ["a", "b", "c"] { try await manager.enqueue(item: movie(id, server: nil), quality: .original) }
        let startedBefore = transport.started.count
        await manager.pause(itemIDs: ["a", "b", "c"])
        #expect(transport.started.count == startedBefore)
        #expect(store.item("c")?.manifest.state == .paused)
    }

    @Test func signingOneAccountOutLeavesWhatAnotherProfileFetchedThroughIt() async throws {
        let (manager, store, _, _) = makeManager(secondaries: ["b": secondary()])
        try await manager.enqueue(item: movie("x", server: "b"), quality: .original)
        await DownloadCleanup.perform(.profile(serverID: "b", userID: "usr"), store: store, manager: manager)
        #expect(store.item("x") != nil)
    }

    @Test func progressSyncsWithTheServerItCameFrom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DHS-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(profile)
        for (id, origin) in [("own", nil), ("home", "b"), ("gone", "c")] as [(String, String?)] {
            var manifest = DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                            mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: Date())
            manifest.originServerID = origin
            manifest.progress = DownloadLocalProgress(positionTicks: 5, played: false, lastPlayed: Date(), lastSyncedAt: nil)
            manifest.transition(to: .downloading)
            manifest.transition(to: .complete)
            let item = movie(id, server: origin)
            let src = try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"s"}"#.utf8))
            try store.create(manifest, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src))
        }
        let stale = try JSONDecoder().decode(UserItemData.self, from: Data(#"{"PlaybackPositionTicks":1,"Played":false,"LastPlayedDate":"2020-01-01T00:00:00Z"}"#.utf8))
        let own = FakeUserDataService(answers: ["own": stale])
        let home = FakeUserDataService(answers: ["home": stale])
        let sync = DownloadProgressSync(store: store) { origin in
            switch origin {
            case nil: (own, "usr")
            case "b": (home, "b-user")
            default: nil
            }
        }
        await sync.run()
        #expect(own.updates.map(\.itemID) == ["own"])
        #expect(home.updates.map(\.itemID) == ["home"])
        #expect(store.item("gone")?.manifest.progress.lastSyncedAt == nil)
    }
}
