import Foundation
import Testing
@testable import Sodalite

@MainActor
struct CombinedLiveTVTests {
    final class FakeLive: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
        var channelCount = 0
        var delay: Duration = .zero
        var fail = false
        struct NotUsed: Error {}
        func getChannels(userID: String, startIndex: Int, limit: Int, filter: GuideFilter) async throws -> LiveTvChannelsResponse {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if fail { throw URLError(.cannotConnectToHost) }
            let items = try (0..<channelCount).map { i in
                try JSONDecoder().decode(JellyfinChannel.self, from: Data(#"{"Id":"c\#(i)","Name":"C\#(i)"}"#.utf8))
            }
            return LiveTvChannelsResponse(items: items, totalRecordCount: items.count)
        }
        func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
        func getGuideInfo() async throws -> JellyfinGuideInfo { throw NotUsed() }
        func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
        func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
        func getTimers() async throws -> [LiveTvTimer] { [] }
        func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
        func createTimer(programID: String) async throws {}
        func cancelTimer(timerID: String) async throws {}
        func createSeriesTimer(programID: String) async throws {}
        func cancelSeriesTimer(timerID: String) async throws {}
        func getRecommendedPrograms(userID: String, category: LiveProgramCategory, limit: Int) async throws -> [JellyfinProgram] { [] }
    }

    private func source(_ id: String, _ live: FakeLive, active: Bool) -> LiveTVSource {
        let client = JellyfinClient()
        return LiveTVSource(serverID: id, serverName: id.uppercased(), userID: "u-\(id)", liveTvService: live,
                            playbackService: JellyfinPlaybackService(client: client),
                            itemService: JellyfinItemService(client: client), isActive: active)
    }

    @Test func capableServersKeepParticipantOrder() async {
        let a = FakeLive(); a.channelCount = 1
        let b = FakeLive(); b.channelCount = 3
        let ids = await LiveTVProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .seconds(1))
        #expect(ids == ["a", "b"])
    }

    @Test func activeWithoutLiveTVStillYieldsTheSecondary() async {
        let a = FakeLive()
        let b = FakeLive(); b.channelCount = 1
        let ids = await LiveTVProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .seconds(1))
        #expect(ids == ["b"])
    }

    @Test func aFailingSecondaryIsLeftOut() async {
        let a = FakeLive(); a.channelCount = 1
        let b = FakeLive(); b.fail = true
        let ids = await LiveTVProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .seconds(1))
        #expect(ids == ["a"])
    }

    @Test func aSlowSecondaryIsLeftOutAfterTheDeadline() async {
        let a = FakeLive(); a.channelCount = 1
        let b = FakeLive(); b.channelCount = 1; b.delay = .seconds(5)
        let started = ContinuousClock.now
        let ids = await LiveTVProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)], secondaryDeadline: .milliseconds(200))
        #expect(ids == ["a"])
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func channelsAndProgramsDecodeTheirServer() throws {
        let channel = try JSONDecoder().decode(JellyfinChannel.self, from: Data(
            #"{"Id":"c","Name":"C","ServerId":"srv-b"}"#.utf8))
        let program = try JSONDecoder().decode(JellyfinProgram.self, from: Data(
            #"{"Id":"p","Name":"P","ServerId":"srv-b"}"#.utf8))
        let bare = try JSONDecoder().decode(JellyfinChannel.self, from: Data(#"{"Id":"c","Name":"C"}"#.utf8))
        #expect(channel.serverID == "srv-b")
        #expect(program.serverID == "srv-b")
        #expect(bare.serverID == nil)
    }
}
