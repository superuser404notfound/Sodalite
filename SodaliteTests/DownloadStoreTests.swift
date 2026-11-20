import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadStoreTests {
    private func makeStore() -> (DownloadStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (DownloadStore(paths: DownloadPaths(root: root)), root)
    }

    private func item(_ id: String, type: String = "Movie") -> JellyfinItem {
        let json = #"{"Id":"\#(id)","Name":"Item \#(id)","Type":"\#(type)","RunTimeTicks":36000000000}"#
        return try! JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func source(_ id: String) -> PlaybackMediaSource {
        let json = #"{"Id":"\#(id)","Container":"mkv","Size":1000,"Bitrate":8000000,"MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"},{"Index":1,"Type":"Audio","Codec":"eac3","Language":"eng"},{"Index":2,"Type":"Subtitle","Codec":"subrip","Language":"ger","IsExternal":true}]}"#
        return try! JSONDecoder().decode(PlaybackMediaSource.self, from: Data(json.utf8))
    }

    private func manifest(_ id: String, state: DownloadState = .queued) -> DownloadManifest {
        DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: .original, route: .original,
                         mediaSourceID: "src-\(id)", audioStreamIndex: nil, playSessionID: nil,
                         state: state, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    private let profile = ProfileKey(serverID: "srv", userID: "usr")

    @Test func manifestSurvivesARoundTrip() throws {
        var m = manifest("a")
        m.subtitleFiles = [2: "sub-2.srt"]
        m.progress = DownloadLocalProgress(positionTicks: 42, played: false,
                                           lastPlayed: Date(timeIntervalSince1970: 5), lastSyncedAt: nil)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(DownloadManifest.self, from: data) == m)
    }

    @Test func allowedTransitions() {
        var m = manifest("a")
        let t1 = m.transition(to: .downloading)
        #expect(t1)
        let t2 = m.transition(to: .paused)
        #expect(t2)
        let t3 = m.transition(to: .queued)
        #expect(t3)
        let t4 = m.transition(to: .downloading)
        #expect(t4)
        let t5 = m.transition(to: .complete)
        #expect(t5)
        let t6 = m.transition(to: .missingOnServer)
        #expect(t6)
        let t7 = m.transition(to: .complete)
        #expect(t7)
    }

    @Test func refusedTransitions() {
        var m = manifest("a", state: .complete)
        let t8 = m.transition(to: .downloading)
        #expect(!t8)
        let t9 = m.transition(to: .queued)
        #expect(!t9)
        #expect(m.state == .complete)
        var q = manifest("b")
        let t10 = q.transition(to: .complete)
        #expect(!t10)
    }

    @Test func aFailureIsClearedByRequeueing() {
        var m = manifest("a", state: .downloading)
        m.failure = .network
        let t11 = m.transition(to: .failed)
        #expect(t11)
        let t12 = m.transition(to: .queued)
        #expect(t12)
        #expect(m.failure == nil)
    }

    @Test func createWritesManifestAndSnapshotAndReloads() throws {
        let (store, root) = makeStore()
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        let reopened = DownloadStore(paths: DownloadPaths(root: root))
        reopened.activate(profile)
        #expect(reopened.item("a")?.manifest == manifest("a"))
        #expect(reopened.item("a")?.snapshot.source.mediaStreams?.count == 3)
    }

    @Test func rootIsExcludedFromBackup() throws {
        let (store, root) = makeStore()
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func itemsAreScopedToTheActiveProfile() throws {
        let (store, _) = makeStore()
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        store.activate(ProfileKey(serverID: "srv", userID: "kid"))
        #expect(store.items.isEmpty)
        store.activate(profile)
        #expect(store.items.count == 1)
    }

    @Test func updatePersists() throws {
        let (store, root) = makeStore()
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        try store.update(itemID: "a") { $0.receivedBytes = 512 }
        let reopened = DownloadStore(paths: DownloadPaths(root: root))
        reopened.activate(profile)
        #expect(reopened.item("a")?.manifest.receivedBytes == 512)
    }

    @Test func completedItemIgnoresUnfinishedDownloads() throws {
        let (store, _) = makeStore()
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        #expect(store.completedItem("a") == nil)
        try store.update(itemID: "a") { $0.transition(to: .downloading); $0.transition(to: .complete); $0.mediaFileName = "media.mkv" }
        try Data(count: 1).write(to: store.item("a")!.directory.appendingPathComponent("media.mkv"))
        #expect(store.completedItem("a") != nil)
    }

    @Test func deleteProfileRemovesOnlyThatProfile() throws {
        let (store, root) = makeStore()
        let other = ProfileKey(serverID: "srv", userID: "kid")
        store.activate(other)
        _ = try store.create(manifest("k"), snapshot: DownloadSnapshot(item: item("k"), series: nil, season: nil, source: source("k")))
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        try store.deleteProfile(serverID: "srv", userID: "usr")
        #expect(store.items.isEmpty)
        let paths = DownloadPaths(root: root)
        #expect(!FileManager.default.fileExists(atPath: paths.profileDirectory(serverID: "srv", userID: "usr").path))
        #expect(FileManager.default.fileExists(atPath: paths.itemDirectory(serverID: "srv", userID: "kid", itemID: "k").path))
    }

    @Test func deleteServerRemovesAllItsProfiles() throws {
        let (store, root) = makeStore()
        store.activate(ProfileKey(serverID: "other", userID: "u"))
        _ = try store.create(manifest("o"), snapshot: DownloadSnapshot(item: item("o"), series: nil, season: nil, source: source("o")))
        store.activate(profile)
        _ = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        try store.deleteServer(serverID: "srv")
        let paths = DownloadPaths(root: root)
        #expect(!FileManager.default.fileExists(atPath: paths.serverDirectory(serverID: "srv").path))
        #expect(FileManager.default.fileExists(atPath: paths.serverDirectory(serverID: "other").path))
        #expect(store.items.isEmpty)
    }

    @Test func usageCountsFilesAndItems() throws {
        let (store, _) = makeStore()
        store.activate(profile)
        let created = try store.create(manifest("a"), snapshot: DownloadSnapshot(item: item("a"), series: nil, season: nil, source: source("a")))
        try Data(count: 4096).write(to: created.directory.appendingPathComponent("media.mkv"))
        let usage = store.usage(serverID: "srv", userID: "usr")
        #expect(usage.items == 1)
        #expect(usage.bytes >= 4096)
    }

    @Test func hostileIDsStayInsideTheRoot() {
        let paths = DownloadPaths(root: URL(fileURLWithPath: "/r"))
        let dir = paths.itemDirectory(serverID: "../x", userID: "a/b", itemID: "..")
        #expect(dir.standardizedFileURL.path.hasPrefix("/r/"))
        #expect(!dir.path.contains("/../"))
    }
}
