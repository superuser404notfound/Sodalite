import Foundation
import Testing
@testable import Sodalite

/// Sodalite#85: the Music tab is gated and served across the combined servers, as Live TV is.
@MainActor
struct CombinedMusicTests {
    final class FakeMusic: JellyfinMusicServiceProtocol, @unchecked Sendable {
        var hasLibrary = false
        var fail = false
        var delay: Duration = .zero
        var albums: [JellyfinItem] = []
        struct Boom: Error {}

        func getAlbums(userID: String) async throws -> [JellyfinItem] { albums }
        func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem] { [] }
        func getAllSongs(userID: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func hasMusicLibrary(userID: String) async throws -> Bool {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if fail { throw Boom() }
            return hasLibrary
        }
    }

    private func source(_ id: String, _ music: FakeMusic, active: Bool) -> MusicSource {
        MusicSource(serverID: id, serverName: id.uppercased(), userID: "u-\(id)", musicService: music, isActive: active)
    }

    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func activeWithoutMusicStillYieldsTheSecondary() async {
        let a = FakeMusic()
        let b = FakeMusic(); b.hasLibrary = true
        let ids = await MusicProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .seconds(1))
        #expect(ids == ["b"])
    }

    @Test func capableServersKeepParticipantOrder() async {
        let a = FakeMusic(); a.hasLibrary = true
        let b = FakeMusic(); b.hasLibrary = true
        let ids = await MusicProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .seconds(1))
        #expect(ids == ["a", "b"])
    }

    @Test func aFailingProbeCountsAsNoMusic() async {
        let a = FakeMusic(); a.fail = true
        let b = FakeMusic(); b.fail = true
        let ids = await MusicProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .seconds(1))
        #expect(ids.isEmpty)
    }

    @Test func aSlowSecondaryKeepsItsLastAnswer() async {
        let a = FakeMusic()
        let b = FakeMusic(); b.hasLibrary = true; b.delay = .seconds(5)
        let ids = await MusicProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)],
            secondaryDeadline: .milliseconds(200), previouslyCapable: ["b"])
        #expect(ids == ["b"])
    }

    @Test func albumsWithoutAServerAreStampedWithTheirSource() async throws {
        let music = FakeMusic()
        music.albums = [
            try item(#"{"Id":"a1","Name":"A1","Type":"MusicAlbum"}"#),
            try item(#"{"Id":"a2","Name":"A2","Type":"MusicAlbum","ServerId":"srv-x"}"#),
        ]
        let model = MusicHomeViewModel()
        await model.load(service: music, userID: "u", serverID: "srv-b")
        #expect(model.albums.map(\.serverID) == ["srv-b", "srv-x"])
    }

    @Test func musicSitsWithTheOtherMediaTabs() {
        #expect(AppTab.probedTabs(hasLiveTV: true, hasMusic: true)
            == [.home, .liveTV, .music, .catalog, .search, .settings])
    }
}
