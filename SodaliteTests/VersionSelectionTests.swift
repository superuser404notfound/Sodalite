import Testing
import Foundation
@testable import Sodalite

/// Sodalite#139: the version choice existed but only behind the Play press, so a merged multi-version
/// movie looked single-version on the page. The affordance is now a button, which means the choice has
/// to outlive the sheet, and a choice that outlives its sheet can outlive its item too. These pin the
/// rules that keep it honest: which version stands by default, and the two ways a pick goes stale.
struct VersionSelectionTests {

    /// Two versions of one movie in the order Jellyfin sends them: the item's own file first (1080p),
    /// the linked 4K alternate second.
    private static let twoVersionJSON = #"""
    {"Id":"movie-1","Name":"Captain America","Type":"Movie",
     "MediaSources":[
       {"Id":"src-original","Name":"Captain America (2014)","Container":"mkv",
        "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
       {"Id":"src-transcode","Name":"5SE3v3","Container":"mkv",
        "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}
     ]}
    """#

    private static let otherEpisodeJSON = #"""
    {"Id":"episode-2","Name":"Episode 2","Type":"Episode",
     "MediaSources":[
       {"Id":"ep2-a","Name":"A","Container":"mkv"},
       {"Id":"ep2-b","Name":"B","Container":"mkv"}
     ]}
    """#

    private func decode(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    // MARK: - The default

    /// Untouched, the page stands on the best version, not on the server's primary. Jellyfin sorts
    /// the item's own file first (here the 1080p original), which says which file the scanner met
    /// first, not which one a 4K Apple TV should play.
    @Test func defaultsToTheBestVersionRatherThanTheServersPrimary() throws {
        let item = try decode(Self.twoVersionJSON)
        let selection = VersionSelection()
        #expect(selection.preferredSourceID(for: item) == "src-transcode")
        #expect(selection.resolvedSource(for: item)?.id == "src-transcode")
    }

    /// Frame size leads and bitrate only breaks ties: a fat 1080p remux is not the better version of
    /// a 4K encode, however many bits it spends.
    @Test func frameSizeOutranksBitrate() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[
           {"Id":"remux-1080","Name":"Remux","Bitrate":38000000,
            "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
           {"Id":"encode-4k","Name":"4K","Bitrate":12000000,
            "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}
         ]}
        """#)
        #expect(VersionSelection().preferredSourceID(for: item) == "encode-4k")
    }

    /// Two versions the app cannot tell apart keep the server's order, and keep it across reads:
    /// `sorted(by:)` is not stable, so an unranked pair would otherwise swap between renders.
    @Test func equalVersionsKeepTheServersOrder() throws {
        let item = try decode(Self.otherEpisodeJSON)
        let sources = try #require(item.mediaSources)
        #expect(sources.rankedByQuality().map(\.id) == ["ep2-a", "ep2-b"])
        #expect(VersionSelection().preferredSourceID(for: item) == "ep2-a")
    }

    /// One version is not a choice, so nothing is preferred and playback keeps the path it had
    /// before any of this: `PlaybackInfo`'s own first source.
    @Test func aSingleVersionPrefersNothing() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie","MediaSources":[{"Id":"only","Name":"Only"}]}
        """#)
        #expect(VersionSelection().preferredSourceID(for: item) == nil)
        #expect(VersionSelection().resolvedSource(for: item)?.id == "only")
    }

    // MARK: - The choice

    /// Picking the lesser version is a real choice too, and the one the default cannot express.
    @Test func aChoiceSurvivesTheSheetAndDrivesPlayback() throws {
        let item = try decode(Self.twoVersionJSON)
        var selection = VersionSelection()
        let picked = try #require(item.mediaSources?.first)
        selection.choose(picked, for: item)
        #expect(selection.preferredSourceID(for: item) == "src-original")
        #expect(selection.resolvedSource(for: item)?.id == "src-original")
    }

    // MARK: - The two ways a choice goes stale

    /// Source ids belong to an item. The series page keeps one selection across episode taps, so a
    /// choice made for one episode must not follow the viewer to the next.
    @Test func aChoiceDoesNotFollowTheViewerToAnotherItem() throws {
        let movie = try decode(Self.twoVersionJSON)
        let episode = try decode(Self.otherEpisodeJSON)
        var selection = VersionSelection()
        selection.choose(try #require(movie.mediaSources?.first), for: movie)
        #expect(selection.preferredSourceID(for: episode) == "ep2-a")
        #expect(selection.resolvedSource(for: episode)?.id == "ep2-a")
    }

    /// A re-fetch can drop the version that was chosen (unmerged on the server, file gone). The page
    /// falls back to the default rather than asking playback for an id the item no longer has.
    @Test func aChoiceThatTheItemNoLongerCarriesFallsBackToTheDefault() throws {
        let item = try decode(Self.twoVersionJSON)
        var selection = VersionSelection()
        selection.choose(try #require(item.mediaSources?.first), for: item)

        let unmerged = try decode(#"""
        {"Id":"movie-1","Name":"Captain America","Type":"Movie",
         "MediaSources":[{"Id":"src-original","Name":"Captain America (2014)","Container":"mkv"}]}
        """#)
        #expect(selection.preferredSourceID(for: unmerged) == nil)
        #expect(selection.resolvedSource(for: unmerged)?.id == "src-original")
    }

    // MARK: - The gate

    /// One version is not a choice, and an item whose fields never carried MediaSources (every episode
    /// list query) must not grow a button that opens an empty sheet.
    @Test func theButtonIsOfferedOnlyWhenThereIsSomethingToChoose() throws {
        #expect(VersionSelection.isOffered(for: try decode(Self.twoVersionJSON)))
        #expect(!VersionSelection.isOffered(for: try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie","MediaSources":[{"Id":"only","Name":"Only"}]}
        """#)))
        #expect(!VersionSelection.isOffered(for: try decode(#"{"Id":"m","Name":"M","Type":"Movie"}"#)))
    }

    // MARK: - Absent items

    /// Both detail pages hand the launcher an optional item (the series page's play target resolves
    /// late), so the nil case has to answer rather than force an unwrap at the call site.
    @Test func anAbsentItemPrefersNothing() throws {
        let item = try decode(Self.twoVersionJSON)
        var selection = VersionSelection()
        selection.choose(try #require(item.mediaSources?.first), for: item)
        #expect(selection.preferredSourceID(for: nil) == nil)
    }
}
