import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 LTV-4. A program's server snapshot carries timer ids that outlive a cancel made
/// elsewhere, and an Overview card offered "Cancel recording" for a timer that no longer existed.
@MainActor
struct LiveTimerStoreSnapshotTests {

    private func program(_ id: String, timer: String?, series: String?) -> JellyfinProgram {
        JellyfinProgram(
            id: id, channelId: "c1", channelName: "Test", name: id, overview: nil,
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: true, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: timer, seriesTimerId: series)
    }

    /// Recordings cancelled the timer; the sync on the way back must cover programs the Overview holds.
    @Test func aSyncedSnapshotNoLongerResurrectsACancelledTimer() async {
        let store = LiveTimerStore(service: EmptyTimerService(), userID: "u")
        let card = program("p1", timer: "t1", series: nil)
        await store.syncWithServer(knownPrograms: [card])
        #expect(store.effectiveTimerState(for: card).timerId == nil)
    }

    /// Cancelling a series from one popover kills every episode timer it spawned, including those on
    /// cards whose snapshot the overlay never saw.
    @Test func aCancelledSeriesClearsEverySnapshotThatNamesIt() async {
        let store = LiveTimerStore(service: EmptyTimerService(), userID: "u")
        let pressed = program("p1", timer: "t1", series: "s1")
        let sibling = program("p2", timer: "t2", series: "s1")
        let unrelated = program("p3", timer: "t3", series: "s2")

        store.toggleSeriesRecord(program: pressed)
        for _ in 0..<1000 where store.effectiveTimerState(for: sibling).seriesTimerId != nil {
            await Task.yield()
        }

        #expect(store.effectiveTimerState(for: sibling).timerId == nil)
        #expect(store.effectiveTimerState(for: sibling).seriesTimerId == nil)
        #expect(store.effectiveTimerState(for: unrelated).timerId == "t3")
    }
}

private final class EmptyTimerService: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    func getChannels(userID: String, startIndex: Int, limit: Int, filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(items: [], totalRecordCount: 0)
    }
    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
    func getGuideInfo() async throws -> JellyfinGuideInfo { JellyfinGuideInfo(startDate: nil, endDate: nil) }
    func getRecommendedPrograms(userID: String, category: LiveProgramCategory, limit: Int) async throws -> [JellyfinProgram] { [] }
    func getProgramIndex(userID: String, window: GuideProgramWindow, genres: String?, category: GuideFilter.Category?, cap: Int) async throws -> [JellyfinProgram] { [] }
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
    func getTimers() async throws -> [LiveTvTimer] { [] }
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
    func createTimer(programID: String) async throws {}
    func cancelTimer(timerID: String) async throws {}
    func createSeriesTimer(programID: String) async throws {}
    func cancelSeriesTimer(timerID: String) async throws {}
}
