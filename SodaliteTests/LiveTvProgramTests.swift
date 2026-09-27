import Testing
import Foundation
@testable import Sodalite

/// Decoding + endpoint coverage for the EPG metadata fields added to `JellyfinProgram`.
@MainActor
struct LiveTvProgramTests {
    private let decoder = JSONDecoder.jellyfinLiveTv

    @Test func programDecodesEpisodeMetadata() throws {
        let json = """
        {"Id":"p1","Name":"The One After Ross Says Rachel","ChannelId":"c1",
         "SeriesName":"Friends","ParentIndexNumber":5,"IndexNumber":1,
         "EpisodeTitle":"The One After Ross Says Rachel"}
        """
        let program = try decoder.decode(JellyfinProgram.self, from: Data(json.utf8))
        #expect(program.seriesName == "Friends")
        #expect(program.parentIndexNumber == 5)
        #expect(program.indexNumber == 1)
        #expect(program.episodeTitle == "The One After Ross Says Rachel")
    }

    @Test func programDecodesWithoutEpisodeMetadata() throws {
        let json = """
        {"Id":"p2","Name":"Evening News","ChannelId":"c2"}
        """
        let program = try decoder.decode(JellyfinProgram.self, from: Data(json.utf8))
        #expect(program.seriesName == nil)
        #expect(program.parentIndexNumber == nil)
        #expect(program.indexNumber == nil)
        #expect(program.episodeTitle == nil)
    }

    @Test func liveTvProgramsQueryIncludesEpisodeFields() {
        let endpoint = JellyfinEndpoint.liveTvPrograms(
            channelIDs: ["c1"], userID: "u1",
            minEndDate: Date(timeIntervalSince1970: 0),
            maxStartDate: Date(timeIntervalSince1970: 3600))
        let fields = endpoint.queryItems?.first(where: { $0.name == "Fields" })?.value
        #expect(fields?.contains("SeriesName") == true)
        #expect(fields?.contains("EpisodeTitle") == true)
        #expect(fields?.contains("ParentIndexNumber") == true)
        #expect(fields?.contains("IndexNumber") == true)
    }

    @Test func liveTvRecommendedProgramsQueryIncludesEpisodeFields() {
        let endpoint = JellyfinEndpoint.liveTvRecommendedPrograms(
            userID: "u1", category: .series, limit: 20)
        let fields = endpoint.queryItems?.first(where: { $0.name == "Fields" })?.value
        #expect(fields?.contains("ChannelInfo") == true)
        #expect(fields?.contains("SeriesName") == true)
                #expect(fields?.contains("EpisodeTitle") == true)
    }

    // #170: without IsAiring the server runs a plain program query, which returns programs that ended since the last guide refresh.
    @Test(arguments: LiveProgramCategory.allCases)
    func recommendedProgramsQueryExcludesEndedPrograms(category: LiveProgramCategory) {
        let items = JellyfinEndpoint.liveTvRecommendedPrograms(userID: "u1", category: category, limit: 20).queryItems ?? []
        let hasAired = items.first(where: { $0.name == "HasAired" })?.value
        #expect(hasAired == (category == .airing ? nil : "false"))
    }

    @Test func seriesRowExcludesOtherCategoriesLikeJellyfinWebEpisodes() {
        let items = JellyfinEndpoint.liveTvRecommendedPrograms(userID: "u1", category: .series, limit: 20).queryItems ?? []
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        #expect(value("IsSeries") == "true")
        #expect(value("IsMovie") == "false")
        #expect(value("IsSports") == "false")
        #expect(value("IsKids") == "false")
        #expect(value("IsNews") == "false")
    }
}
