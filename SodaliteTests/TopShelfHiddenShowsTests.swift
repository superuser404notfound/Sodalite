import Foundation
import Testing
@testable import Sodalite

@Suite("Top Shelf hidden shows")
struct TopShelfHiddenShowsTests {

    private static func item(_ id: String, series: String?) throws -> TopShelfItem {
        let seriesField = series.map { #","SeriesId":"\#($0)""# } ?? ""
        let json = #"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode"\#(seriesField)}"#
        return try JSONDecoder().decode(TopShelfItem.self, from: Data(json.utf8))
    }

    @Test("an episode of a hidden show leaves the shelf, a movie stays")
    func removesHiddenSeries() throws {
        let items = [try Self.item("e1", series: "s1"),
                     try Self.item("e2", series: "s2"),
                     try Self.item("m1", series: nil)]
        let kept = TopShelfItem.removingHidden(items, hidden: ["s1"])
        #expect(kept.map(\.id) == ["e2", "m1"])
    }

    /// The mirror can lag a profile switch; another user's list must not empty this user's shelf.
    @Test("a mirror written for another user hides nothing")
    func otherUserHidesNothing() {
        let mirror = TopShelfHiddenShows(userID: "u1", seriesIDs: ["s1"])
        #expect(mirror.hidden(for: "u1") == ["s1"])
        #expect(mirror.hidden(for: "u2").isEmpty)
    }

    /// A combined shelf asks the profile's other servers too (Sodalite#218), so their hidden shows
    /// cross over keyed by server, and the active server's stay where an older extension reads them.
    @Test("the mirror carries every server, the own one in its old place")
    func mirrorKeepsOwnServer() throws {
        let profile = ProfileKey(serverID: "srv-\(UUID().uuidString)", userID: "u1")
        let scope = profile.storageScope
        let list = [DroppedSeries(seriesID: "s1", name: "One", serverID: profile.serverID),
                    DroppedSeries(seriesID: "s2", name: "Two", serverID: "other")]
        DroppedSeriesStore.setRawData(try JSONEncoder().encode(list), scope: scope)
        defer { UserDefaults.standard.removeObject(forKey: "homeDroppedSeries.\(scope)") }

        let mirror = DroppedSeriesStore.shelfMirror(for: profile)
        #expect(mirror == TopShelfHiddenShows(userID: "u1", seriesIDs: ["s1"], otherServers: ["other": ["s2"]]))
    }

    @Test("each server's items are filtered by that server's list")
    func hiddenPerServer() {
        let mirror = TopShelfHiddenShows(userID: "u1", seriesIDs: ["s1"], otherServers: ["b": ["s2"]])
        #expect(mirror.hidden(for: "u1", serverID: nil) == ["s1"])
        #expect(mirror.hidden(for: "u1", serverID: "b") == ["s2"])
        #expect(mirror.hidden(for: "u1", serverID: "c").isEmpty)
        #expect(mirror.hidden(for: "u2", serverID: "b").isEmpty)
    }

    /// The extension of an earlier build wrote no `otherServers`; that mirror still has to decode.
    @Test("a mirror without other servers still decodes")
    func decodesOldMirror() throws {
        let mirror = try JSONDecoder().decode(TopShelfHiddenShows.self,
                                              from: Data(#"{"userID":"u1","seriesIDs":["s1"]}"#.utf8))
        #expect(mirror.hidden(for: "u1", serverID: nil) == ["s1"])
        #expect(mirror.otherServers == nil)
    }
}
