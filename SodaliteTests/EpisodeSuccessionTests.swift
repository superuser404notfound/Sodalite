import Foundation
import Testing
@testable import Sodalite

/// Sodalite#230: the episode page and the player's auto-advance share one successor rule, and the
/// page only moves on after a stop that finished the episode.
struct EpisodeSuccessionTests {
    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func episode(_ id: String, season: String = "s1", index: Int?, runtime: Int64? = 1_000) throws -> JellyfinItem {
        let indexField = index.map { #","IndexNumber":\#($0)"# } ?? ""
        let runtimeField = runtime.map { #","RunTimeTicks":\#($0)"# } ?? ""
        return try item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"show","SeasonId":"\#(season)"\#(indexField)\#(runtimeField)}"#)
    }

    private func season(_ id: String, index: Int) throws -> JellyfinItem {
        try item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Season","IndexNumber":\#(index)}"#)
    }

    @Test func nextIsTheLowestLaterIndexWhateverTheListOrder() throws {
        let list = [try episode("e5", index: 5), try episode("e3", index: 3), try episode("e4", index: 4)]
        #expect(EpisodeSuccession.next(after: list[1], in: list)?.id == "e4")
    }

    @Test func noNextAfterTheLastEpisodeOfASeason() throws {
        let list = [try episode("e1", index: 1), try episode("e2", index: 2)]
        #expect(EpisodeSuccession.next(after: list[1], in: list) == nil)
    }

    @Test func anEpisodeWithoutAnIndexHasNoNext() throws {
        let list = [try episode("e1", index: nil), try episode("e2", index: 2)]
        #expect(EpisodeSuccession.next(after: list[0], in: list) == nil)
    }

    /// A finale rolls into the next numbered season, past the specials (season 0).
    @Test func seasonAfterSkipsSpecials() throws {
        let seasons = [try season("specials", index: 0), try season("s2", index: 2), try season("s1", index: 1)]
        #expect(EpisodeSuccession.season(after: "s1", in: seasons)?.id == "s2")
        #expect(EpisodeSuccession.season(after: "s2", in: seasons) == nil)
    }

    @Test func firstIsTheLowestIndex() throws {
        let list = [try episode("e2", index: 2), try episode("e1", index: 1)]
        #expect(EpisodeSuccession.first(in: list)?.id == "e1")
    }

    /// The same 90% Jellyfin uses: below it the stop leaves a resume position, and the page stays.
    @Test func finishedMeansPastTheWatchedThreshold() throws {
        let ep = try episode("e1", index: 1, runtime: 1_000)
        #expect(ep.isFinished(byStopAt: 1_000))
        #expect(ep.isFinished(byStopAt: 900))
        #expect(!ep.isFinished(byStopAt: 899))
        // A stop at zero on an episode already watched is the state a re-opened page is in, not a finish.
        #expect(!ep.isFinished(byStopAt: 0))
    }

    @Test func withoutARuntimeNothingCountsAsFinished() throws {
        let ep = try episode("e1", index: 1, runtime: nil)
        #expect(!ep.isFinished(byStopAt: 5_000))
    }
}

/// The page-side lookup: same season first, then into the next one, nothing after the last.
@MainActor
struct DetailViewModelSuccessorTests {
    private typealias Service = DetailViewModelRefreshSeasonsTests.MockItemService

    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func episode(_ id: String, season: String, index: Int) throws -> JellyfinItem {
        try item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"show","SeasonId":"\#(season)","IndexNumber":\#(index)}"#)
    }

    private func season(_ id: String, index: Int) throws -> JellyfinItem {
        try item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Season","IndexNumber":\#(index)}"#)
    }

    private func makeViewModel(_ service: Service) throws -> DetailViewModel {
        let vm = DetailViewModel(
            item: try item(#"{"Id":"show","Name":"Show","Type":"Series"}"#),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
        vm.seasons = [try season("s1", index: 1), try season("s2", index: 2)]
        return vm
    }

    @Test func staysInTheSeasonWhileItHasMore() async throws {
        let service = Service()
        service.episodesBySeason = ["s1": [try episode("s1e3", season: "s1", index: 3), try episode("s1e4", season: "s1", index: 4)]]
        let vm = try makeViewModel(service)
        #expect(await vm.successor(of: try episode("s1e3", season: "s1", index: 3))?.id == "s1e4")
    }

    @Test func crossesIntoTheNextSeasonAfterAFinale() async throws {
        let service = Service()
        service.episodesBySeason = [
            "s1": [try episode("s1e8", season: "s1", index: 8)],
            "s2": [try episode("s2e2", season: "s2", index: 2), try episode("s2e1", season: "s2", index: 1)]
        ]
        let vm = try makeViewModel(service)
        #expect(await vm.successor(of: try episode("s1e8", season: "s1", index: 8))?.id == "s2e1")
    }

    /// The last available episode has no successor, so the page keeps Play Again.
    @Test func noSuccessorAfterTheLastEpisode() async throws {
        let service = Service()
        service.episodesBySeason = ["s2": [try episode("s2e5", season: "s2", index: 5)]]
        let vm = try makeViewModel(service)
        #expect(await vm.successor(of: try episode("s2e5", season: "s2", index: 5)) == nil)
    }
}
