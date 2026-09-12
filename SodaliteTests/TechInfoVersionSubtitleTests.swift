import Testing
import Foundation
@testable import Sodalite

/// Sodalite#139, second round: the tech cards follow the chosen version, but nothing on the page
/// said so, so the section read as a statement about the film. The line under the heading names the
/// version the cards describe. These pin when it appears and what it says.
struct TechInfoVersionSubtitleTests {

    private func decode(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    /// The reporter's own library: a merged movie whose versions carry the server's names.
    private static let twoVersionJSON = #"""
    {"Id":"movie-1","Name":"Captain America","Type":"Movie",
     "MediaSources":[
       {"Id":"src-original","Name":"Captain America The Winter Soldier (2014)","Container":"mkv",
        "Size":31000000000,
        "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
       {"Id":"src-transcode","Name":"5SE3v3","Container":"mkv","Size":2520000000,
        "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":1920,"Height":1080}]}
     ]}
    """#

    /// One file is not a choice, so a caption under the heading would only ever repeat the cards.
    @Test func aSingleVersionItemGetsNoSubtitle() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[{"Id":"only","Name":"M (2014)","Container":"mkv"}]}
        """#)
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: nil) == nil)
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: "only") == nil)
    }

    /// A slim item (a query that never asked for MediaSources) has nothing to name.
    @Test func anItemWithoutSourcesGetsNoSubtitle() throws {
        let item = try decode(#"{"Id":"m","Name":"M","Type":"Movie"}"#)
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: nil) == nil)
    }

    /// The server's version name carries the line. The specs stay out of it: resolution, codec and
    /// size are spelled out in the cards an inch below.
    @Test func theSubtitleNamesTheChosenVersion() throws {
        let item = try decode(Self.twoVersionJSON)
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: "src-transcode") == "5SE3v3")
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: "src-original")
                == "Captain America The Winter Soldier (2014)")
    }

    /// Untouched, the page stands on the best version, and the line has to agree with the cards,
    /// which read the same default through `effectiveMediaSource(id:)`.
    @Test func theSubtitleFollowsTheDefaultWhenNothingIsChosen() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[
           {"Id":"hd","Name":"1080p Remux","MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
           {"Id":"uhd","Name":"4K","MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}
         ]}
        """#)
        let selection = VersionSelection()
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: selection.preferredSourceID(for: item)) == "4K")
    }

    /// Jellyfin does not promise a name. Where it is missing the derived specs step in, because a
    /// blank line under the heading is worse than a repetitive one.
    @Test func anUnnamedVersionFallsBackToItsSpecs() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[
           {"Id":"a","Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]},
           {"Id":"b","Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]}
         ]}
        """#)
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: "b") == "1080p · H264")
    }

    /// A name of nothing but spaces is the same case as no name at all.
    @Test func aBlankNameFallsBackToItsSpecs() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[
           {"Id":"a","Name":"   ","Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]},
           {"Id":"b","Name":"Second","Container":"mkv"}
         ]}
        """#)
        #expect(TechInfoBox.versionSubtitle(for: item, sourceID: "a") == "4K · HEVC")
    }

    /// A source id from another item, or from a version the server dropped between fetches, resolves
    /// to the default rather than to nothing: the cards do the same, and the two must not disagree.
    @Test func aStaleSourceIDStillNamesWhatTheCardsShow() throws {
        let item = try decode(Self.twoVersionJSON)
        let subtitle = TechInfoBox.versionSubtitle(for: item, sourceID: "from-another-item")
        #expect(subtitle == item.effectiveMediaSource(id: "from-another-item")?.name)
        #expect(subtitle != nil)
    }
}
