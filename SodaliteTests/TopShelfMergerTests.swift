import Foundation
import Testing
@testable import Sodalite

/// The combined shelf (Sodalite#218) has to show Home's rows: same order, same copy of a title on
/// two servers. Every case decodes one JSON into both item types and asks both mergers.
@MainActor
struct TopShelfMergerTests {
    private struct Fixture {
        let json: String
        let server: String
    }

    private func fixture(_ id: String, server: String, type: String = "Episode", _ extra: String = "") -> Fixture {
        let tail = extra.isEmpty ? "" : ",\(extra)"
        return Fixture(json: #"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)","ServerId":"\#(server)"\#(tail)}"#,
                       server: server)
    }

    private func home(_ lists: [[Fixture]]) throws -> [[JellyfinItem]] {
        try lists.map { try $0.map { try JSONDecoder().decode(JellyfinItem.self, from: Data($0.json.utf8)) } }
    }

    private func shelf(_ lists: [[Fixture]]) throws -> [[TopShelfItem]] {
        try lists.enumerated().map { index, list in
            try list.map {
                try JSONDecoder().decode(TopShelfItem.self, from: Data($0.json.utf8))
                    .stamped(serverID: index == 0 ? nil : $0.server)
            }
        }
    }

    private func played(_ date: String, ticks: Int = 5) -> String {
        #""UserData":{"LastPlayedDate":"\#(date)","PlaybackPositionTicks":\#(ticks)}"#
    }

    private func origin(_ items: [JellyfinItem]) -> [String] { items.map { "\($0.id)@\($0.serverID ?? "")" } }
    private func origin(_ items: [TopShelfItem], active: String) -> [String] {
        items.map { "\($0.id)@\($0.sourceServerID ?? active)" }
    }

    @Test func continueWatchingMatchesHome() throws {
        let lists = [
            [fixture("a1", server: "a", played("2026-10-01T20:00:00Z")),
             fixture("a2", server: "a", played("2026-09-01T20:00:00Z"))],
            [fixture("b1", server: "b", played("2026-09-15T20:00:00Z"))],
        ]
        let expected = HomeMerger.merge(try home(lists), type: .continueWatching, mergedContinueWatching: false)
        let merged = TopShelfMerger.resume(try shelf(lists), limit: 16)
        #expect(origin(merged, active: "a") == origin(expected))
        #expect(merged.map(\.id) == ["a1", "b1", "a2"])
    }

    /// The same film on both servers, played last on the secondary: Home shows the secondary's copy.
    @Test func continueWatchingKeepsTheNewerCopy() throws {
        let tmdb = #""ProviderIds":{"Tmdb":"603"}"#
        let lists = [
            [fixture("ma", server: "a", type: "Movie", played("2026-09-01T00:00:00Z") + "," + tmdb)],
            [fixture("mb", server: "b", type: "Movie", played("2026-10-01T00:00:00Z") + "," + tmdb)],
        ]
        let expected = HomeMerger.merge(try home(lists), type: .continueWatching, mergedContinueWatching: false)
        let merged = TopShelfMerger.resume(try shelf(lists), limit: 16)
        #expect(origin(merged, active: "a") == origin(expected))
        #expect(merged.map(\.id) == ["mb"])
        #expect(merged.first?.sourceServerID == "b")
    }

    @Test func nextUpMatchesHome() throws {
        let tvdb = #""ProviderIds":{"Tvdb":"42"}"#
        let lists = [
            [fixture("a1", server: "a"), fixture("a2", server: "a", tvdb), fixture("a3", server: "a")],
            [fixture("b1", server: "b"), fixture("b2", server: "b", tvdb)],
        ]
        let expected = HomeMerger.merge(try home(lists), type: .nextUp, mergedContinueWatching: false)
        let merged = TopShelfMerger.nextUp(try shelf(lists), limit: 16)
        #expect(origin(merged, active: "a") == origin(expected))
        #expect(merged.map(\.id) == ["a1", "b1", "a2", "a3"])
    }

    /// Of two copies the one with progress wins, even from the secondary.
    @Test func nextUpPrefersTheCopyWithProgress() throws {
        let tvdb = #""ProviderIds":{"Tvdb":"42"}"#
        let lists = [
            [fixture("a1", server: "a", tvdb)],
            [fixture("b1", server: "b", played("2026-10-01T00:00:00Z", ticks: 9) + "," + tvdb)],
        ]
        let expected = HomeMerger.merge(try home(lists), type: .nextUp, mergedContinueWatching: false)
        let merged = TopShelfMerger.nextUp(try shelf(lists), limit: 16)
        #expect(origin(merged, active: "a") == origin(expected))
        #expect(merged.map(\.id) == ["b1"])
    }

    @Test func oneServerComesBackUnchanged() throws {
        let lists = [[fixture("b", server: "a"), fixture("a", server: "a")]]
        #expect(TopShelfMerger.nextUp(try shelf(lists), limit: 10).map(\.id) == ["b", "a"])
        #expect(TopShelfMerger.resume(try shelf(lists), limit: 10).map(\.id) == ["b", "a"])
    }

    @Test func theLimitCapsTheMergedRow() throws {
        let lists = [
            [fixture("a1", server: "a"), fixture("a2", server: "a")],
            [fixture("b1", server: "b"), fixture("b2", server: "b")],
        ]
        #expect(TopShelfMerger.nextUp(try shelf(lists), limit: 3).map(\.id) == ["a1", "b1", "a2"])
    }
}
