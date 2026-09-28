import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadProgressSyncTests {
    private func userData(_ position: Int64, played: Bool, last: String?) -> UserItemData {
        let lastJSON = last.map { #","LastPlayedDate":"\#($0)""# } ?? ""
        let json = #"{"PlaybackPositionTicks":\#(position),"Played":\#(played)\#(lastJSON)}"#
        return try! JSONDecoder().decode(UserItemData.self, from: Data(json.utf8))
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesJellyfinsSevenFractionalDigits() {
        #expect(JellyfinDate.parse("2027-01-15T08:00:00.0000000Z") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(JellyfinDate.parse("2027-01-15T08:00:00Z") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(JellyfinDate.parse(nil) == nil)
        #expect(JellyfinDate.format(Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15T08:00:00.000Z")
    }

    @Test func localNewerIsPushed() {
        let local = DownloadLocalProgress(positionTicks: 900, played: false, lastPlayed: t0.addingTimeInterval(60), lastSyncedAt: nil)
        #expect(DownloadProgressSync.decide(local: local, server: userData(100, played: false, last: "2027-01-15T08:00:00.0000000Z")) == .push)
    }

    @Test func serverNewerIsAdopted() {
        let local = DownloadLocalProgress(positionTicks: 900, played: false, lastPlayed: t0, lastSyncedAt: nil)
        #expect(DownloadProgressSync.decide(local: local, server: userData(100, played: true, last: "2027-01-15T09:00:00.0000000Z")) == .adopt)
    }

    @Test func equalDatesDoNothing() {
        let local = DownloadLocalProgress(positionTicks: 900, played: false, lastPlayed: t0, lastSyncedAt: t0)
        #expect(DownloadProgressSync.decide(local: local, server: userData(900, played: false, last: "2027-01-15T08:00:00.0000000Z")) == .nothing)
    }

    @Test func neverSyncedOfflineWatchIsPushed() {
        let local = DownloadLocalProgress(positionTicks: 500, played: false, lastPlayed: t0, lastSyncedAt: nil)
        #expect(DownloadProgressSync.decide(local: local, server: userData(0, played: false, last: nil)) == .push)
    }

    @Test func neverPlayedLocallyAdopts() {
        let local = DownloadLocalProgress()
        #expect(DownloadProgressSync.decide(local: local, server: userData(300, played: false, last: "2027-01-15T08:00:00.0000000Z")) == .adopt)
    }

    @Test func runPushesAdoptsAndStamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTests-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(ProfileKey(serverID: "s", userID: "u"))
        func make(_ id: String, progress: DownloadLocalProgress) throws {
            var m = DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                     mediaSourceID: "src", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: t0)
            m.progress = progress
            m.transition(to: .downloading)
            m.transition(to: .complete)
            let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"x","Type":"Movie"}"#.utf8))
            let src = try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"src"}"#.utf8))
            try store.create(m, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src))
        }
        try make("local", progress: DownloadLocalProgress(positionTicks: 900, played: false, lastPlayed: t0.addingTimeInterval(3600), lastSyncedAt: nil))
        try make("server", progress: DownloadLocalProgress(positionTicks: 900, played: false, lastPlayed: t0, lastSyncedAt: nil))

        let service = FakeUserDataService(answers: [
            "local": userData(100, played: false, last: "2027-01-15T08:00:00.0000000Z"),
            "server": userData(200, played: true, last: "2027-01-15T09:00:00.0000000Z"),
        ])
        let now = t0.addingTimeInterval(7200)
        let sync = DownloadProgressSync(store: store, service: service, userID: "u", now: { now })
        await sync.run()

        #expect(service.updates.map(\.itemID) == ["local"])
        #expect(service.updates.first?.positionTicks == 900)
        #expect(store.item("server")?.manifest.progress.positionTicks == 200)
        #expect(store.item("server")?.manifest.progress.played == true)
        #expect(store.item("local")?.manifest.progress.lastSyncedAt == now)
        #expect(store.item("server")?.manifest.progress.lastSyncedAt == now)
    }

    @Test func aFailingServerLeavesTheManifestAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTests-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(ProfileKey(serverID: "s", userID: "u"))
        var m = DownloadManifest(itemID: "a", seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                 mediaSourceID: "src", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: t0)
        m.progress = DownloadLocalProgress(positionTicks: 900, played: false, lastPlayed: t0, lastSyncedAt: nil)
        m.transition(to: .downloading)
        m.transition(to: .complete)
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"a","Name":"x","Type":"Movie"}"#.utf8))
        let src = try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"src"}"#.utf8))
        try store.create(m, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src))
        let sync = DownloadProgressSync(store: store, service: FakeUserDataService(answers: [:]), userID: "u", now: { self.t0 })
        await sync.run()
        #expect(store.item("a")?.manifest.progress.lastSyncedAt == nil)
    }
}

final class FakeUserDataService: UserItemDataServing, @unchecked Sendable {
    struct Update: Sendable { let itemID: String; let positionTicks: Int64; let played: Bool }
    private let lock = NSLock()
    private let answers: [String: UserItemData]
    private var _updates: [Update] = []
    var updates: [Update] { lock.withLock { _updates } }
    struct Missing: Error {}

    init(answers: [String: UserItemData]) { self.answers = answers }

    func userData(itemID: String, userID: String) async throws -> UserItemData {
        guard let answer = answers[itemID] else { throw Missing() }
        return answer
    }

    func updateUserData(itemID: String, userID: String, positionTicks: Int64, played: Bool, lastPlayed: Date) async throws {
        lock.withLock { _updates.append(Update(itemID: itemID, positionTicks: positionTicks, played: played)) }
    }
}
