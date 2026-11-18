import Testing
import Foundation
@testable import Sodalite

/// The shared Live TV line-up (audit LTM-R203) and the two fixes that ride on it: a revalidating
/// genre or category match never empties the grid (LTM-203), and the channel list's schedule window
/// moves with the clock (LTM-206).
@MainActor
struct LiveLineupTests {

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }

    private func localDate(hour: Int, minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 17
        parts.hour = hour; parts.minute = minute
        return Calendar.current.date(from: parts) ?? Date()
    }

    private func sportsFilter() -> GuideFilter {
        var filter = GuideFilter.default
        filter.category = .sports
        return filter
    }

    // MARK: - LTM-203

    @Test func aRevalidatingCategoryKeepsTheGridFilledUntilTheNewAnswerLands() async {
        let service = LineupStub()
        service.indexChannels = ["c0", "c1"]
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        await model.apply(filter: sportsFilter())
        #expect(model.channels.map(\.id) == ["c0", "c1"])

        service.armIndexGate()
        service.indexChannels = ["c1"]
        #expect(model.refreshAxis(now: Date().addingTimeInterval(3 * 3600)))
        await settle { service.isHoldingIndex }

        #expect(service.isHoldingIndex)
        #expect(model.channels.map(\.id) == ["c0", "c1"])
        #expect(model.categories.isResolving == false)

        service.releaseIndex()
        await settle { model.channels.map(\.id) == ["c1"] }
        #expect(model.channels.map(\.id) == ["c1"])
    }

    @Test func aFailedRevalidationKeepsTheOldMatch() async {
        let service = LineupStub()
        service.indexChannels = ["c0"]
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        await model.apply(filter: sportsFilter())
        #expect(model.channels.map(\.id) == ["c0"])

        service.failIndex = true
        let before = service.indexCalls
        #expect(model.refreshAxis(now: Date().addingTimeInterval(3 * 3600)))
        await settle { service.indexCalls > before }
        for _ in 0..<50 { await Task.yield() }

        #expect(model.channels.map(\.id) == ["c0"])
        #expect(model.categories.isResolving == false)
    }

    @Test func aUserTappedCategoryStillEmptiesFirst() async {
        let service = LineupStub()
        service.indexChannels = ["c0"]
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        service.armIndexGate()
        let applying = Task { await model.apply(filter: sportsFilter()) }
        await settle { service.isHoldingIndex }

        #expect(model.channels.isEmpty)
        #expect(model.categories.isResolving)
        service.releaseIndex()
        await applying.value
        #expect(model.channels.map(\.id) == ["c0"])
    }

    // MARK: - LTM-206

    @Test func theChannelListMovesItsWindowAndRefetchesARowItAlreadyLoaded() async {
        let service = LineupStub()
        let start = localDate(hour: 10, minute: 5)
        let model = ChannelListViewModel(
            service: service, userID: "u",
            timers: LiveTimerStore(service: service, userID: "u"), now: start)
        await model.load()
        await model.ensurePrograms(for: ["c0"])
        #expect(service.programStarts == [localDate(hour: 10, minute: 0)])

        // Same half hour: nothing moves, nothing is asked again.
        #expect(model.refreshWindow(now: localDate(hour: 10, minute: 20)) == false)
        await model.ensurePrograms(for: ["c0"])
        #expect(service.programStarts.count == 1)

        let epoch = model.requestEpoch
        #expect(model.refreshWindow(now: localDate(hour: 21, minute: 40)))
        #expect(model.requestEpoch != epoch)
        await model.ensurePrograms(for: ["c0"])
        #expect(service.programStarts.last == localDate(hour: 21, minute: 30))
        #expect(service.programStarts.count == 2)
    }

    @Test func pullToRefreshAsksForTheRowsAgainToo() async {
        let service = LineupStub()
        let model = ChannelListViewModel(
            service: service, userID: "u", timers: LiveTimerStore(service: service, userID: "u"))
        await model.load()
        await model.ensurePrograms(for: ["c0"])
        await model.refresh()
        await model.ensurePrograms(for: ["c0"])
        #expect(service.programStarts.count == 2)
    }

    @Test func theListDropsOverlappingEpgEntriesLikeTheGuide() async {
        let service = LineupStub()
        let t = localDate(hour: 12, minute: 0)
        service.programs = [
            LineupStub.program("a", channel: "c0", start: t, end: t.addingTimeInterval(3600)),
            LineupStub.program("b", channel: "c0", start: t.addingTimeInterval(600), end: t.addingTimeInterval(1800)),
        ]
        let model = ChannelListViewModel(
            service: service, userID: "u", timers: LiveTimerStore(service: service, userID: "u"), now: t)
        await model.load()
        await model.ensurePrograms(for: ["c0"])
        #expect(model.programsByChannel["c0"]?.count == 1)
    }
}

/// Three channels on the default filter. The program index answers `indexChannels`, optionally held
/// at a gate or failing; program requests are recorded.
private final class LineupStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var gateArmed = false
    private var gate: CheckedContinuation<Void, Never>?
    private var _indexChannels: [String] = []
    private var _failIndex = false
    private var _indexCalls = 0
    private var _programStarts: [Date] = []
    private var _programs: [JellyfinProgram] = []

    var indexChannels: [String] {
        get { lock.withLock { _indexChannels } }
        set { lock.withLock { _indexChannels = newValue } }
    }
    var failIndex: Bool {
        get { lock.withLock { _failIndex } }
        set { lock.withLock { _failIndex = newValue } }
    }
    var indexCalls: Int { lock.withLock { _indexCalls } }
    var programStarts: [Date] { lock.withLock { _programStarts } }
    var programs: [JellyfinProgram] {
        get { lock.withLock { _programs } }
        set { lock.withLock { _programs = newValue } }
    }
    var isHoldingIndex: Bool { lock.withLock { gate != nil } }

    func armIndexGate() { lock.withLock { gateArmed = true } }
    func releaseIndex() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }

    static func program(_ id: String, channel: String, start: Date, end: Date) -> JellyfinProgram {
        JellyfinProgram(
            id: id, channelId: channel, channelName: nil, name: id, overview: nil,
            startDate: start, endDate: end,
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        if limit == 1 { return LiveTvChannelsResponse(items: [], totalRecordCount: 0) }
        return LiveTvChannelsResponse(
            items: (0..<3).map {
                JellyfinChannel(id: "c\($0)", name: "c\($0)", channelNumber: nil,
                                imageTags: nil, currentProgram: nil, userData: nil)
            },
            totalRecordCount: nil)
    }

    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] {
        lock.withLock {
            _programStarts.append(start)
            return _programs.filter { channelIDs.contains($0.channelId ?? "") }
        }
    }

    func getProgramIndex(userID: String, window: GuideProgramWindow, genres: String?,
                         category: GuideFilter.Category?, cap: Int) async throws -> [JellyfinProgram] {
        let hold = lock.withLock { () -> Bool in
            _indexCalls += 1
            defer { gateArmed = false }
            return gateArmed
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { gate = continuation }
            }
        }
        if failIndex { throw URLError(.notConnectedToInternet) }
        let now = Date()
        return indexChannels.map { Self.program("i-\($0)", channel: $0, start: now, end: now.addingTimeInterval(60)) }
    }

    func getGuideInfo() async throws -> JellyfinGuideInfo { JellyfinGuideInfo(startDate: nil, endDate: nil) }
    func getRecommendedPrograms(userID: String, category: LiveProgramCategory, limit: Int) async throws -> [JellyfinProgram] { [] }
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
    func getTimers() async throws -> [LiveTvTimer] { [] }
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
    func createTimer(programID: String) async throws {}
    func cancelTimer(timerID: String) async throws {}
    func createSeriesTimer(programID: String) async throws {}
    func cancelSeriesTimer(timerID: String) async throws {}
}
