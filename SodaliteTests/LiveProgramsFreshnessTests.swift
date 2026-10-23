import Testing
import Foundation
@testable import Sodalite

/// Sodalite#96: the Übersicht rows come from `/LiveTv/Programs/Recommended`, which answers a
/// question about the current moment. The guide survives the passing of time because its cells are
/// placed by absolute time; these rows are a snapshot, so they need an expiry and a refetch.
@MainActor
struct LiveProgramsFreshnessTests {

    private func program(_ name: String, start: Date, end: Date) -> JellyfinProgram {
        JellyfinProgram(
            id: name, channelId: "c1", channelName: "Test", name: name, overview: nil,
            startDate: start, endDate: end,
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    // MARK: - Expiry

    @Test("the first airing program to end sets the expiry")
    func expiryIsEarliestAiringEnd() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .airing: [program("long", start: now - 600, end: now + 3600),
                      program("short", start: now - 600, end: now + 900)],
            .movies: [program("movie", start: now - 60, end: now + 1800)],
        ]
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now) == now + 900)
    }

    @Test("a program that is not airing yet does not set the expiry")
    func upcomingProgramsDoNotExpireTheSnapshot() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .airing: [program("airing", start: now - 60, end: now + 3600)],
            .movies: [program("tonight", start: now + 300, end: now + 600)],
        ]
        // now+600 is the earlier end date, but that program has not started, so nothing on screen
        // changes when it ends.
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now) == now + 3600)
    }

    @Test("a program about to end still buys the snapshot its minimum lifetime")
    func expiryHasAFloor() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .airing: [program("ending", start: now - 3600, end: now + 10)],
        ]
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now)
                == now + LiveProgramsViewModel.minimumLifetime)
    }

    @Test("nothing airing means nothing to expire on, so the snapshot gets the blind lifetime")
    func expiryWithoutAiringPrograms() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .movies: [program("tonight", start: now + 3600, end: now + 7200)],
        ]
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now)
                == now + LiveProgramsViewModel.unknownScheduleLifetime)
    }

    @Test("an empty answer expires too, so an empty guide is retried rather than kept forever")
    func expiryWithoutRows() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(LiveProgramsViewModel.expiry(for: [:], loadedAt: now)
                == now + LiveProgramsViewModel.unknownScheduleLifetime)
    }

    // MARK: - Refetch policy

    @Test("a second load does not hit the server, and an unexpired refresh does not either")
    func freshSnapshotIsNotRefetched() async {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")

        await model.load()
        let afterFirst = service.requestCount
        #expect(afterFirst == LiveProgramCategory.allCases.count)

        await model.load()
        await model.refreshIfExpired(now: Date())
        #expect(service.requestCount == afterFirst)
    }

    @Test("past the expiry the rows are refetched")
    func expiredSnapshotIsRefetched() async {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")

        await model.load()
        let afterFirst = service.requestCount
        await model.refreshIfExpired(now: Date().addingTimeInterval(3600))
        #expect(service.requestCount == afterFirst * 2)
        #expect(model.rows[.airing]?.isEmpty == false)
    }

    @Test("a refresh that fails everywhere keeps the rows it already had, without an error page")
    func failedRefreshKeepsRows() async {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")
        await model.load()
        #expect(model.rows.isEmpty == false)

        service.failing = true
        await model.refresh()
        #expect(model.rows.isEmpty == false)
        #expect(model.loadError == nil)
    }

    @Test("a failed refresh moves the expiry, so an unreachable server is not asked every 30 seconds")
    func failedRefreshBacksOff() async throws {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")
        await model.load()
        let firstExpiry = try #require(model.validUntil)

        service.failing = true
        // The refetch the clock makes once the snapshot has expired.
        await model.refreshIfExpired(now: Date().addingTimeInterval(3600))
        let secondExpiry = try #require(model.validUntil)

        // Left untouched, the expiry stays in the past and the loop's floor of 30s becomes the
        // whole wait, for as long as the tab is open.
        #expect(secondExpiry != firstExpiry)
        let expected = Date().addingTimeInterval(LiveProgramsViewModel.minimumLifetime)
        #expect(abs(secondExpiry.timeIntervalSince(expected)) < 5)
    }

    @Test("a first load that fails everywhere reports it and stays retryable")
    func failedFirstLoadIsRetryable() async {
        let service = StubLiveTvService(airingFor: 1800)
        service.failing = true
        let model = LiveProgramsViewModel(service: service, userID: "u")

        await model.load()
        #expect(model.loadError != nil)
        #expect(model.validUntil == nil)

        service.failing = false
        await model.load()
        #expect(model.rows.isEmpty == false)
        #expect(model.loadError == nil)
    }

    @Test("a load whose caller goes away still fills the rows instead of painting an error")
    func cancelledCallerDoesNotFailTheLoad() async {
        let service = StubLiveTvService(airingFor: 3600)
        service.delay = .milliseconds(100)
        let model = LiveProgramsViewModel(service: service, userID: "u")

        // What a tab page rebuilt under a profile switch does to the load it started.
        let caller = Task { await model.load() }
        try? await Task.sleep(for: .milliseconds(20))
        caller.cancel()
        await caller.value

        #expect(model.loadError == nil)
        #expect(model.rows.isEmpty == false)
    }
}

/// Counts recommended-programs calls and can be made to fail; every other endpoint is unused here.
private final class StubLiveTvService: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    /// Seconds the returned program still has to run, measured from the moment it is asked for.
    let airingFor: TimeInterval
    var failing = false
    /// Answer time, slept with the caller's cancellation the way URLSession honours it.
    var delay: Duration?

    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }

    init(airingFor: TimeInterval) { self.airingFor = airingFor }

    func getRecommendedPrograms(userID: String, category: LiveProgramCategory,
                                limit: Int) async throws -> [JellyfinProgram] {
        lock.withLock { count += 1 }
        if let delay { try await Task.sleep(for: delay) }
        if failing { throw URLError(.notConnectedToInternet) }
        let now = Date()
        return [JellyfinProgram(
            id: "\(category.rawValue)-1", channelId: "c1", channelName: "Test",
            name: category.rawValue, overview: nil,
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(airingFor),
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)]
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(items: [], totalRecordCount: 0)
    }
    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
    func getGuideInfo() async throws -> JellyfinGuideInfo { JellyfinGuideInfo(startDate: nil, endDate: nil) }
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

/// Sodalite#96, the player half: a live session outlives the programme it tuned into, and both the
/// title above the picture and the system Now Playing entry are built from that one programme.
@MainActor
struct LiveProgramFollowTests {

    private func program(endingIn seconds: TimeInterval?, from now: Date) -> JellyfinProgram {
        JellyfinProgram(
            id: "p", channelId: "c1", channelName: "Test", name: "Programme", overview: nil,
            startDate: now.addingTimeInterval(-600),
            endDate: seconds.map { now.addingTimeInterval($0) },
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    @Test("the next look is the programme's end, which is when the title stops being true")
    func checkLandsOnTheProgramEnd() {
        let now = Date(timeIntervalSince1970: 10_000)
        let end = now.addingTimeInterval(1800)
        #expect(PlayerViewModel.nextLiveProgramCheck(
            after: program(endingIn: 1800, from: now), from: now) == end)
    }

    @Test("a programme about to end is not looked at every second")
    func checkHasAFloor() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(PlayerViewModel.nextLiveProgramCheck(after: program(endingIn: 2, from: now), from: now)
                == now.addingTimeInterval(PlayerViewModel.liveProgramMinimumInterval))
    }

    @Test("nothing known to be on air earns the blind interval, not a retry loop")
    func checkWithoutAProgram() {
        let now = Date(timeIntervalSince1970: 10_000)
        let blind = now.addingTimeInterval(PlayerViewModel.liveProgramBlindInterval)
        // A failed ask reports nothing, and a channel without EPG never had an end date.
        #expect(PlayerViewModel.nextLiveProgramCheck(after: nil, from: now) == blind)
        #expect(PlayerViewModel.nextLiveProgramCheck(
            after: program(endingIn: nil, from: now), from: now) == blind)
    }

    @Test("an end that already passed does not schedule a look in the past")
    func checkWithAnEndedProgram() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(PlayerViewModel.nextLiveProgramCheck(
            after: program(endingIn: -300, from: now), from: now)
                == now.addingTimeInterval(PlayerViewModel.liveProgramBlindInterval))
    }
}
