import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// The row order used to be spelled out as magic indices in four places, and a fifth spot opened the
/// menu on the layout that existed before the secondary header was added.
@MainActor
struct SubtitleMenuLayoutTests {

    private func stream(_ index: Int) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: "subrip", language: "de",
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: false, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    @Test("VOD keeps the shipped order: secondary header, Off, tracks, search")
    func vodOrder() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(3), stream(4)],
                                           supportsSecondary: true, supportsSearch: true)
        #expect(rows == [.secondaryHeader, .off, .track(streamIndex: 3), .track(streamIndex: 4), .searchOnline])
    }

    /// Live has no secondary track and nothing to search, so its menu is Off plus what the channel
    /// carries. This is the shape the old hard-coded indices could not express.
    @Test("live drops the header and the search footer")
    func liveOrder() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(7)],
                                           supportsSecondary: false, supportsSearch: false)
        #expect(rows == [.off, .track(streamIndex: 7)])
    }

    @Test("a track with no subtitles at all still offers Off")
    func emptyStillHasOff() {
        #expect(SubtitleMenuLayout.rows(streams: [], supportsSecondary: false, supportsSearch: true)
                == [.off, .searchOnline])
    }

    @Test("the offset row sits directly above the search footer")
    func offsetAboveSearch() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(3)], supportsSecondary: true,
                                           supportsSearch: true, supportsOffset: true)
        #expect(rows == [.secondaryHeader, .off, .track(streamIndex: 3), .offset, .searchOnline])
    }

    @Test("the offset row closes the menu where there is no search footer")
    func offsetWithoutSearch() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(3)], supportsSecondary: false,
                                           supportsSearch: false, supportsOffset: true)
        #expect(rows == [.off, .track(streamIndex: 3), .offset])
    }

    @Test("the menu opens on the active track")
    func opensOnTheActiveTrack() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(3), stream(4)],
                                           supportsSecondary: true, supportsSearch: true)
        #expect(SubtitleMenuLayout.highlightIndex(forActive: 4, in: rows) == 3)
    }

    @Test("with subtitles off it opens on Off, not on the header above it")
    func opensOnOff() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(3)],
                                           supportsSecondary: true, supportsSearch: true)
        #expect(SubtitleMenuLayout.highlightIndex(forActive: nil, in: rows) == 1)
        #expect(rows[SubtitleMenuLayout.highlightIndex(forActive: nil, in: rows)] == .off)
    }

    /// A remembered id that no longer resolves (episode switch, track list changed) must not leave
    /// the highlight pointing at a row that is not there.
    @Test("an unresolvable active id falls back to Off")
    func unresolvableActiveFallsBack() {
        let rows = SubtitleMenuLayout.rows(streams: [stream(3)],
                                           supportsSecondary: false, supportsSearch: false)
        #expect(SubtitleMenuLayout.highlightIndex(forActive: 99, in: rows) == 0)
    }
}
