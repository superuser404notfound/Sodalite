import Foundation
import Testing
@testable import Sodalite

@MainActor
struct ItemServerOriginTests {
    @Test func itemDecodesServerId() throws {
        let json = #"{"Id":"i1","Name":"Heat","Type":"Movie","ServerId":"srv-a"}"#
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        #expect(item.serverID == "srv-a")
        #expect(item.originKey == "srv-a|i1")
    }

    @Test func itemWithoutServerIdStillDecodes() throws {
        let json = #"{"Id":"i1","Name":"Heat","Type":"Movie"}"#
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        #expect(item.serverID == nil)
        #expect(item.originKey == "|i1")
    }

    @Test func serverIdSurvivesTheCacheRoundTrip() throws {
        let json = #"{"Id":"i1","Name":"Heat","Type":"Movie","ServerId":"srv-a"}"#
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        let again = try JSONDecoder().decode(JellyfinItem.self, from: JSONEncoder().encode(item))
        #expect(again.serverID == "srv-a")
    }

    @Test func libraryDecodesServerId() throws {
        let json = #"{"Id":"lib1","Name":"Movies","CollectionType":"movies","ServerId":"srv-b"}"#
        let library = try JSONDecoder().decode(JellyfinLibrary.self, from: Data(json.utf8))
        #expect(library.serverID == "srv-b")
    }
}
