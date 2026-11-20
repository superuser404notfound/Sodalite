import Testing
import Foundation
@testable import Sodalite

/// The channel fetch loops of the guide grid and the iPhone channel list: what survives a filter switch
/// in the middle of paging.
@MainActor
struct LiveChannelLoadingTests {

    private var favorites: GuideFilter {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        return filter
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    // MARK: - Audit 2026-09-25 LTV-2

    /// The replacement fetch used to hit the `isLoading` re-entry guard and return, and the old loop then
    /// quit on its generation check: nobody fetched for the new filter and the grid sat on its spinner.
    @Test func aFilterSwitchMidPagingLoadsTheNewFilterInTheGuide() async {
        let service = ChannelStub(gateFirstDefaultPage: true)
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        let first = Task { await model.load() }
        await settle { service.isHoldingDefaultPage }

        await model.apply(filter: favorites)
        service.releaseDefaultPage()
        await first.value

        #expect(model.channels.map(\.id) == ["f0", "f1"])
        #expect(model.channelsComplete)
        #expect(model.isLoadingChannels == false)
    }

    @Test func aFilterSwitchMidPagingLoadsTheNewFilterInTheChannelList() async {
        let service = ChannelStub(gateFirstDefaultPage: true)
        let model = ChannelListViewModel(service: service, userID: "u",
                                         timers: LiveTimerStore(service: service, userID: "u"))
        let first = Task { await model.load() }
        await settle { service.isHoldingDefaultPage }

        await model.apply(filter: favorites)
        service.releaseDefaultPage()
        await first.value

        #expect(model.channels.map(\.id) == ["f0", "f1"])
        #expect(model.isLoading == false)
    }
}

/// Default filter: one short page of three "d" channels, optionally held until released. Favorites: two
/// "f" channels. The one-item radio probe gets nothing.
private final class ChannelStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var gateArmed: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(gateFirstDefaultPage: Bool = false) {
        self.gateArmed = gateFirstDefaultPage
    }

    var isHoldingDefaultPage: Bool { lock.withLock { gate != nil } }

    func releaseDefaultPage() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }

    private func page(_ prefix: String, count: Int, from start: Int = 0) -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(
            items: (start..<(start + count)).map {
                JellyfinChannel(id: "\(prefix)\($0)", name: "\(prefix)\($0)", channelNumber: nil,
                                imageTags: nil, currentProgram: nil, userData: nil)
            },
            totalRecordCount: nil)
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        if limit == 1 { return LiveTvChannelsResponse(items: [], totalRecordCount: 0) }
        if filter.favoritesOnly { return page("f", count: 2) }
        let hold = lock.withLock { () -> Bool in
            defer { gateArmed = false }
            return gateArmed
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { gate = continuation }
            }
        }
        return page("d", count: 3, from: startIndex)
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

// MARK: - Audit 2026-09-25 LTV-3

@MainActor
struct LiveChannelRecoveryTests {

    @Test func aFailedFirstPageCanBeRetriedInTheGuide() async {
        let service = RecoveryStub()
        service.failNext = true
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        #expect(model.loadError != nil)
        #expect(model.channels.isEmpty)

        await model.recover()
        #expect(model.loadError == nil)
        #expect(model.channels.count == 3)
        #expect(model.channelsComplete)
    }

    @Test func aFailedFirstPageCanBeRetriedInTheChannelList() async {
        let service = RecoveryStub()
        service.failNext = true
        let model = ChannelListViewModel(service: service, userID: "u",
                                         timers: LiveTimerStore(service: service, userID: "u"))
        await model.load()
        #expect(model.loadError != nil)

        await model.recover()
        #expect(model.loadError == nil)
        #expect(model.channels.count == 3)
    }

    /// The reload signal fires on every route change; a guide that is fine must not refetch or blank.
    @Test func recoveringAHealthyGuideDoesNothing() async {
        let service = RecoveryStub()
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        let requests = service.pageRequests
        await model.recover()
        #expect(service.pageRequests == requests)
        #expect(model.channels.count == 3)
    }
}

private final class RecoveryStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    var failNext = false
    private(set) var pageRequests = 0

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        if limit == 1 { return LiveTvChannelsResponse(items: [], totalRecordCount: 0) }
        pageRequests += 1
        if failNext {
            failNext = false
            throw URLError(.timedOut)
        }
        return LiveTvChannelsResponse(
            items: (0..<3).map {
                JellyfinChannel(id: "c\($0)", name: "c\($0)", channelNumber: nil,
                                imageTags: nil, currentProgram: nil, userData: nil)
            },
            totalRecordCount: nil)
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
