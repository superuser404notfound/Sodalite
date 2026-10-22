import Testing
import Foundation
@testable import Sodalite

/// Sodalite#195. Jellyfin's `RemoteTrailers` come from TMDB as YouTube links, and the embed page
/// interpolates the id it is handed, so the parser is both the feature's gate and its input check.
struct RemoteTrailerTests {
    private func id(_ url: String?) -> String? {
        RemoteTrailer(url: url, name: nil).youTubeVideoID
    }

    @Test("every link shape TMDB and hand-edited metadata produce resolves to the id", arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "http://youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=10",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "www.youtube.com/watch?v=dQw4w9WgXcQ",
        "  https://www.YouTube.com/watch?v=dQw4w9WgXcQ \n",
    ])
    func resolvesKnownShapes(url: String) {
        #expect(id(url) == "dQw4w9WgXcQ")
    }

    @Test("anything that is not an 11-character YouTube id stays out of the embed page", arguments: [
        "https://vimeo.com/123456789",
        "https://www.youtube.com/channel/UCabcdefghijk",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=dQw4w9WgXc'",
        "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        "",
    ])
    func rejectsEverythingElse(url: String) {
        #expect(id(url) == nil)
    }

    @Test("a nil URL has no id")
    func nilURL() {
        #expect(id(nil) == nil)
    }

    @Test("the item decodes RemoteTrailers and takes the first entry that resolves")
    func itemPicksFirstYouTubeTrailer() throws {
        let json = """
        {"Id":"m1","Name":"M1","Type":"Movie",
         "RemoteTrailers":[{"Url":"https://vimeo.com/1"},
                           {"Url":"https://www.youtube.com/watch?v=aaaaaaaaaaa","Name":"Official Trailer"},
                           {"Url":"https://www.youtube.com/watch?v=bbbbbbbbbbb"}]}
        """
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        #expect(item.youTubeTrailer == YouTubeTrailer(videoID: "aaaaaaaaaaa", title: "Official Trailer"))
        #expect(item.youTubeTrailer?.watchURL.absoluteString == "https://www.youtube.com/watch?v=aaaaaaaaaaa")
    }

    @Test("an item without the field has no remote trailer")
    func itemWithoutField() throws {
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"m1","Name":"M1","Type":"Movie"}"#.utf8))
        #expect(item.remoteTrailers == nil)
        #expect(item.youTubeTrailer == nil)
    }

    @Test("the detail field set asks the server for RemoteTrailers")
    func detailFieldsRequestRemoteTrailers() {
        #expect(JellyfinEndpoint.detailFields.split(separator: ",").contains("RemoteTrailers"))
    }
}
