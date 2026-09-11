import Testing
import Foundation
@testable import Sodalite

/// Sodalite#139: the version choice existed but only behind the Play press, so a merged multi-version
/// movie looked single-version on the page. The affordance is now a button, which means the choice has
/// to outlive the sheet, and a choice that outlives its sheet can outlive its item too. These pin the
/// four rules that keep it honest.
struct VersionSelectionTests {

    /// Two versions of one movie, the original first (that is the order the server sends, and the one
    /// playback falls back to).
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

    /// Untouched, the page describes the server's first source and hands playback nothing, so the
    /// player keeps the exact fallback it had before the button existed.
    @Test func defaultsToTheServersFirstSourceAndPrefersNothing() throws {
        let item = try decode(Self.twoVersionJSON)
        let selection = VersionSelection()
        #expect(selection.preferredSourceID(for: item) == nil)
        #expect(selection.resolvedSource(for: item)?.id == "src-original")
    }

    // MARK: - The choice

    @Test func aChoiceSurvivesTheSheetAndDrivesPlayback() throws {
        let item = try decode(Self.twoVersionJSON)
        var selection = VersionSelection()
        let picked = try #require(item.mediaSources?.last)
        selection.choose(picked, for: item)
        #expect(selection.preferredSourceID(for: item) == "src-transcode")
        #expect(selection.resolvedSource(for: item)?.id == "src-transcode")
    }

    // MARK: - The two ways a choice goes stale

    /// Source ids belong to an item. The series page keeps one selection across episode taps, so a
    /// choice made for one episode must not follow the viewer to the next.
    @Test func aChoiceDoesNotFollowTheViewerToAnotherItem() throws {
        let movie = try decode(Self.twoVersionJSON)
        let episode = try decode(Self.otherEpisodeJSON)
        var selection = VersionSelection()
        selection.choose(try #require(movie.mediaSources?.last), for: movie)
        #expect(selection.preferredSourceID(for: episode) == nil)
        #expect(selection.resolvedSource(for: episode)?.id == "ep2-a")
    }

    /// A re-fetch can drop the version that was chosen (unmerged on the server, file gone). The page
    /// falls back to the default rather than asking playback for an id the item no longer has.
    @Test func aChoiceThatTheItemNoLongerCarriesFallsBackToTheDefault() throws {
        let item = try decode(Self.twoVersionJSON)
        var selection = VersionSelection()
        selection.choose(try #require(item.mediaSources?.last), for: item)

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
        selection.choose(try #require(item.mediaSources?.last), for: item)
        #expect(selection.preferredSourceID(for: nil) == nil)
    }
}
