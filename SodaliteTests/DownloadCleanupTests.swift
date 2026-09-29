import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadCleanupTests {
    private func seeded() throws -> (DownloadStore, DownloadPaths) {
        let paths = DownloadPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("DC-\(UUID().uuidString)"))
        let store = DownloadStore(paths: paths)
        for (server, user, id) in [("a", "u1", "i1"), ("a", "u2", "i2"), ("b", "u1", "i3")] {
            store.activate(ProfileKey(serverID: server, userID: user))
            let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"x","Type":"Movie"}"#.utf8))
            let src = try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"s"}"#.utf8))
            try store.create(DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                              mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: Date()),
                             snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src))
        }
        store.activate(ProfileKey(serverID: "a", userID: "u1"))
        return (store, paths)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func profileScopeRemovesExactlyThatProfile() async throws {
        let (store, paths) = try seeded()
        #expect(DownloadCleanup.usage(.profile(serverID: "a", userID: "u1"), store: store).items == 1)
        await DownloadCleanup.perform(.profile(serverID: "a", userID: "u1"), store: store, manager: nil)
        #expect(!exists(paths.profileDirectory(serverID: "a", userID: "u1")))
        #expect(exists(paths.profileDirectory(serverID: "a", userID: "u2")))
        #expect(exists(paths.profileDirectory(serverID: "b", userID: "u1")))
    }

    @Test func serverScopeRemovesThatServerOnly() async throws {
        let (store, paths) = try seeded()
        #expect(DownloadCleanup.usage(.server("a"), store: store).items == 2)
        await DownloadCleanup.perform(.server("a"), store: store, manager: nil)
        #expect(!exists(paths.serverDirectory(serverID: "a")))
        #expect(exists(paths.serverDirectory(serverID: "b")))
    }

    @Test func everythingRemovesTheRoot() async throws {
        let (store, paths) = try seeded()
        #expect(DownloadCleanup.usage(.everything, store: store).items == 3)
        await DownloadCleanup.perform(.everything, store: store, manager: nil)
        #expect(!exists(paths.root))
    }

    @Test func warningOnlyWithDownloads() {
        #expect(DownloadCleanup.warning(for: .init(items: 0, bytes: 0)) == nil)
        #expect(DownloadCleanup.warning(for: .init(items: 2, bytes: 2_000_000_000)) != nil)
    }
}
