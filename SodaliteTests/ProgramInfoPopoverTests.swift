import Testing
import SwiftUI
@testable import Sodalite

/// Characterizes the `episodeLabel` cascade: episode title > series name > bare S/E > nil.
@MainActor
struct ProgramInfoPopoverTests {
    /// Stub channel so the popover initializer has a non-optional channel.
    private let channel = JellyfinChannel(
        id: "c1", name: "Test Channel", channelNumber: nil,
        imageTags: nil, currentProgram: nil, userData: nil)

    /// Builds a minimal program with only the episode-identity fields set.
    private func program(
        episodeTitle: String? = nil,
        seriesName: String? = nil,
        parentIndexNumber: Int? = nil,
        indexNumber: Int? = nil
    ) -> JellyfinProgram {
        JellyfinProgram(
            id: "p1", channelId: nil, channelName: nil,
            name: "Program Name", overview: nil,
            startDate: nil, endDate: nil,
            genres: nil, imageTags: nil,
            isLive: nil, isNews: nil, isMovie: nil, isSeries: nil,
            isKids: nil, isSports: nil,
            seriesName: seriesName,
            parentIndexNumber: parentIndexNumber,
            indexNumber: indexNumber,
            episodeTitle: episodeTitle,
            timerId: nil, seriesTimerId: nil)
    }

    private func label(
        episodeTitle: String? = nil,
        seriesName: String? = nil,
        parentIndexNumber: Int? = nil,
        indexNumber: Int? = nil
    ) -> String? {
        let prog = program(
            episodeTitle: episodeTitle, seriesName: seriesName,
            parentIndexNumber: parentIndexNumber, indexNumber: indexNumber)
        return ProgramInfoPopover(
            program: prog, channel: channel, tint: .blue).episodeLabel
    }

    // MARK: - Full metadata

    @Test func episodeTitleWithSeasonEpisode() {
        #expect(label(episodeTitle: "Ross Finds Out",
                       parentIndexNumber: 2, indexNumber: 21)
                == "S2:E21 · Ross Finds Out")
    }

    @Test func seriesNameWithSeasonEpisode() {
        #expect(label(seriesName: "Friends",
                       parentIndexNumber: 3, indexNumber: 15)
                == "Friends · S3:E15")
    }

    // MARK: - Title / series without S/E

    @Test func episodeTitleWithoutSeasonEpisode() {
        #expect(label(episodeTitle: "Pilot") == "Pilot")
    }

    @Test func seriesNameWithoutSeasonEpisode() {
        #expect(label(seriesName: "Local News") == "Local News")
    }

    // MARK: - S/E only

    @Test func seasonEpisodeWithoutTitleOrSeries() {
        #expect(label(parentIndexNumber: 4, indexNumber: 8) == "S4:E8")
    }

    // MARK: - Priority cascade

    @Test func episodeTitleBeatsSeriesName() {
        #expect(label(episodeTitle: "The Finale", seriesName: "The Show",
                       parentIndexNumber: 1, indexNumber: 10)
                == "S1:E10 · The Finale")
    }

    @Test func seriesNameBeatsBareSE() {
        // No episode title, so series name wins over bare S/E.
        // (seriesName is already tested above with S/E; this is the bare-S/E
        // case where seriesName is present — it's the same branch.)
        #expect(label(seriesName: "The Show",
                       parentIndexNumber: 1, indexNumber: 10)
                == "The Show · S1:E10")
    }

    // MARK: - Nil

    @Test func returnsNilWhenNoMetadata() {
        #expect(label() == nil)
    }
}
