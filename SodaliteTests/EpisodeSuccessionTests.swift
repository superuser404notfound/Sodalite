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

    @Test func anEpisodeWithoutIndexOrAirDateHasNoNext() throws {
        let list = [try episode("e1", index: nil), try episode("e2", index: 2)]
        #expect(EpisodeSuccession.next(after: list[0], in: list) == nil)
    }

    private func dated(_ id: String, aired: String, name: String? = nil) throws -> JellyfinItem {
        try item(#"{"Id":"\#(id)","Name":"\#(name ?? id)","Type":"Episode","SeriesId":"show","SeasonId":"s2024","PremiereDate":"\#(aired)"}"#)
    }

    /// Date-based shows carry an air date and no episode number. Auto-advance went back to the list
    /// on them (Reddit report, a daily show with "Autoplay Next Episode" on).
    @Test func aDatedEpisodeAdvancesToTheNextAirDate() throws {
        let list = [
            try dated("mar3", aired: "2024-03-03T00:00:00.0000000Z"),
            try dated("mar1", aired: "2024-03-01T00:00:00.0000000Z"),
            try dated("mar2", aired: "2024-03-02T00:00:00.0000000Z"),
        ]
        #expect(EpisodeSuccession.next(after: list[1], in: list)?.id == "mar2")
        #expect(EpisodeSuccession.next(after: list[2], in: list)?.id == "mar3")
        #expect(EpisodeSuccession.next(after: list[0], in: list) == nil)
    }

    @Test func twoEditionsOnOneDayFollowTheirNames() throws {
        let list = [
            try dated("b", aired: "2024-03-01T00:00:00Z", name: "B evening"),
            try dated("a", aired: "2024-03-01T00:00:00Z", name: "A morning"),
            try dated("c", aired: "2024-03-02T00:00:00Z"),
        ]
        #expect(EpisodeSuccession.next(after: list[1], in: list)?.id == "b")
        #expect(EpisodeSuccession.next(after: list[0], in: list)?.id == "c")
    }

    @Test func aSeasonOfDatedEpisodesStartsAtTheOldest() throws {
        let list = [try dated("mar2", aired: "2024-03-02T00:00:00Z"), try dated("mar1", aired: "2024-03-01T00:00:00Z")]
        #expect(EpisodeSuccession.first(in: list)?.id == "mar1")
        #expect(EpisodeSuccession.sortedInDiscOrder(list).map(\.id) == ["mar1", "mar2"])
    }

    /// An extra with neither number nor date has no place in the season. The player must stop there
    /// instead of reading the nil successor as a finale and jumping into the next season.
    @Test func anEpisodeWithoutIndexOrDateCannotAdvance() throws {
        #expect(!EpisodeSuccession.canAdvance(from: try episode("extra", index: nil)))
        #expect(EpisodeSuccession.canAdvance(from: try episode("e1", index: 1)))
        #expect(EpisodeSuccession.canAdvance(from: try dated("mar1", aired: "2024-03-01T00:00:00Z")))
    }

    /// A dated special in a numbered season moves on to the next dated special, never to a numbered
    /// episode that happens to air later, and the picker lists the specials after the numbered run.
    @Test func anUnnumberedSpecialSkipsTheNumberedRun() throws {
        let e1 = try item(#"{"Id":"e1","Name":"e1","Type":"Episode","SeriesId":"show","SeasonId":"s2024","IndexNumber":1,"PremiereDate":"2024-03-01T00:00:00Z"}"#)
        let jan = try dated("jan", aired: "2024-01-01T00:00:00Z")
        let feb = try dated("feb", aired: "2024-02-01T00:00:00Z")
        let list = [e1, feb, jan]
        #expect(EpisodeSuccession.next(after: jan, in: list)?.id == "feb")
        #expect(EpisodeSuccession.next(after: feb, in: list) == nil)
        #expect(EpisodeSuccession.sortedInDiscOrder(list).map(\.id) == ["e1", "jan", "feb"])
    }

    /// A numbered episode keeps the index rule even when air dates disagree with it.
    @Test func numberedEpisodesIgnoreAirDates() throws {
        let e1 = try item(#"{"Id":"e1","Name":"e1","Type":"Episode","SeriesId":"show","SeasonId":"s1","IndexNumber":1,"PremiereDate":"2024-03-05T00:00:00Z"}"#)
        let e2 = try item(#"{"Id":"e2","Name":"e2","Type":"Episode","SeriesId":"show","SeasonId":"s1","IndexNumber":2,"PremiereDate":"2024-03-01T00:00:00Z"}"#)
        #expect(EpisodeSuccession.next(after: e1, in: [e2, e1])?.id == "e2")
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
