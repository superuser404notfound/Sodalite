import Foundation
import Testing
@testable import Sodalite

@Suite("Media segment request")
struct MediaSegmentRequestTests {
    @Test("the segments endpoint asks for intro, outro, recap and commercial")
    func requestsEverySkippableSegmentType() {
        let items = JellyfinEndpoint.mediaSegments(itemID: "abc").queryItems ?? []
        let types = items.filter { $0.name == "includeSegmentTypes" }.compactMap(\.value)
        #expect(Set(types) == ["Intro", "Outro", "Recap", "Commercial"])
    }

    @Test("a recap marker decodes into the paired result")
    func recapDecodes() throws {
        let json = """
        {"Items":[
          {"Id":"1","ItemId":"abc","Type":"Recap","StartTicks":0,"EndTicks":300000000},
          {"Id":"2","ItemId":"abc","Type":"Intro","StartTicks":300000000,"EndTicks":900000000}
        ],"TotalRecordCount":2}
        """
        let response = try JSONDecoder().decode(MediaSegmentsResponse.self, from: Data(json.utf8))
        let segments = EpisodeSegments(items: response.items)
        #expect(segments.recap?.endSeconds == 30)
        #expect(segments.intro?.startSeconds == 30)
        #expect(segments.outro == nil)
        #expect(segments.commercials.isEmpty)
    }

    @Test("every commercial break is kept, in playback order (Sodalite#224)")
    func commercialsDecodeSorted() throws {
        let json = """
        {"Items":[
          {"Id":"2","ItemId":"abc","Type":"Commercial","StartTicks":15000000000,"EndTicks":16800000000},
          {"Id":"1","ItemId":"abc","Type":"Commercial","StartTicks":6000000000,"EndTicks":7800000000}
        ],"TotalRecordCount":2}
        """
        let response = try JSONDecoder().decode(MediaSegmentsResponse.self, from: Data(json.utf8))
        let segments = EpisodeSegments(items: response.items)
        #expect(segments.commercials.map(\.startSeconds) == [600, 1500])
        #expect(segments.intro == nil)
    }
}
