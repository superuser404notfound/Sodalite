import Foundation
import Testing
@testable import Sodalite

@Suite("Dropped series", .serialized)
@MainActor
struct DroppedSeriesTests {
    private func episode(_ id: String, series: String?, server: String? = nil) throws -> JellyfinItem {
        var fields = #""Id":"\#(id)","Name":"\#(id)","Type":"Episode""#
        if let series { fields += #","SeriesId":"\#(series)","SeriesName":"Show \#(series)""# }
        if let server { fields += #","ServerId":"\#(server)""# }
        return try JSONDecoder().decode(JellyfinItem.self, from: Data("{\(fields)}".utf8))
    }

    private func freshScope() -> String { "dropped-\(UUID().uuidString)" }

    @Test func droppingAShowHidesItsEpisodesOnThatServerOnly() throws {
        let scope = freshScope()
        let dropped = try episode("e1", series: "s1")
        DroppedSeriesStore.drop(dropped, fallbackServerID: "main", scope: scope)

        let items = [
            try episode("e2", series: "s1"),
            try episode("e3", series: "s1", server: "other"),
            try episode("e4", series: "s2"),
            try episode("m1", series: nil),
        ]
        let kept = DroppedSeriesStore.filter(items, serverID: "main", scope: scope).map(\.id)
        #expect(kept == ["e3", "e4", "m1"])
        #expect(DroppedSeriesStore.load(scope: scope).map(\.name) == ["Show s1"])
    }

    @Test func droppingTwiceKeepsOneEntryAndRestoreBringsItBack() throws {
        let scope = freshScope()
        let item = try episode("e1", series: "s1", server: "srv")
        DroppedSeriesStore.drop(item, fallbackServerID: "main", scope: scope)
        DroppedSeriesStore.drop(item, fallbackServerID: "main", scope: scope)
        #expect(DroppedSeriesStore.load(scope: scope).count == 1)

        DroppedSeriesStore.restore("srv|s1", scope: scope)
        #expect(DroppedSeriesStore.load(scope: scope).isEmpty)
        #expect(DroppedSeriesStore.filter([item], serverID: "main", scope: scope).count == 1)
    }

    @Test func theListTravelsInTheHomeRecordButNotIntoANewProfile() throws {
        let source = freshScope()
        let synced = freshScope()
        let seeded = freshScope()
        DroppedSeriesStore.drop(try episode("e1", series: "s1"), fallbackServerID: "main", scope: source)

        ProfileHomeStore.apply(ProfileHomeStore.collect(scope: source, stamp: Date()), scope: synced)
        #expect(DroppedSeriesStore.load(scope: synced) == DroppedSeriesStore.load(scope: source))

        ProfileHomeStore.copy(fromScope: source, toScope: seeded)
        #expect(DroppedSeriesStore.load(scope: seeded).isEmpty)
    }
}
