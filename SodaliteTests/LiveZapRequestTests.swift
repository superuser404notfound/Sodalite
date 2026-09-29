import Testing
import Foundation
@testable import Sodalite

@MainActor
struct LiveZapRequestTests {
    private func makeViewModel(liveChannelID: String, zapFilter: GuideFilter,
                               service: JellyfinLiveTvServiceProtocol) -> PlayerViewModel {
        let channel = JellyfinChannel(id: liveChannelID, name: liveChannelID, channelNumber: nil,
                                      imageTags: nil, currentProgram: nil, userData: nil)
        return PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: RecordingPlaybackService(),
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.zaprequest.\(UUID())")!),
            isLiveSession: true,
            liveChannel: channel,
            liveTvService: service,
            zapFilter: zapFilter)
    }

    @Test func twoPressesMoveTheTargetTwice() async {
        let vm = makeViewModel(liveChannelID: "a1", zapFilter: .default, service: LineupStub())
        vm.loadZapLineupIfNeeded()
        let load = vm.zapLineupTask
        _ = await load?.value
        vm.requestZap(by: 1)
        vm.requestZap(by: 1)
        #expect(vm.zapPendingOffset == 2)
        #expect(vm.zapBanner?.channel?.id == "a3")
        vm.zapSettleTask?.cancel()
    }

    @Test func aPressBeforeTheLineupLoadsIsResolvedAfterIt() async {
        let stub = LineupStub(holdFirstPage: true)
        let vm = makeViewModel(liveChannelID: "a1", zapFilter: .default, service: stub)
        vm.loadZapLineupIfNeeded()
        let load = vm.zapLineupTask
        vm.requestZap(by: -1)
        #expect(vm.zapBanner == LiveZapBanner(channel: nil, direction: -1))
        stub.release()
        _ = await load?.value
        #expect(vm.zapBanner?.channel?.id == "a0")
        vm.zapSettleTask?.cancel()
    }

    @Test func aChannelOutsideTheFavouritesZapsThroughAllChannels() async {
        var favourites = GuideFilter.default
        favourites.favoritesOnly = true
        let vm = makeViewModel(liveChannelID: "a2", zapFilter: favourites, service: LineupStub())
        vm.loadZapLineupIfNeeded()
        let load = vm.zapLineupTask
        _ = await load?.value
        #expect(vm.zapLineup?.contains("a2") == true)
        vm.requestZap(by: 1)
        #expect(vm.zapBanner?.channel?.id == "a3")
        vm.zapSettleTask?.cancel()
    }

    @Test func aFailedLineupLoadLeavesThePressInert() async {
        let vm = makeViewModel(liveChannelID: "a1", zapFilter: .default, service: LineupStub(fails: true))
        vm.loadZapLineupIfNeeded()
        let load = vm.zapLineupTask
        _ = await load?.value
        vm.requestZap(by: 1)
        #expect(vm.zapTarget == nil)
        #expect(vm.zapLineup == nil)
        #expect(vm.zapBanner == LiveZapBanner(channel: nil, direction: 1))
        vm.zapSettleTask?.cancel()
    }

    @Test func aPressThatSettlesBeforeTheLineupTunesOnceItArrives() async {
        let stub = LineupStub(holdFirstPage: true)
        let vm = makeViewModel(liveChannelID: "a1", zapFilter: .default, service: stub)
        var started: String?
        vm.zapStartPlayback = { started = vm.liveChannel?.id }
        vm.requestZap(by: 1)
        await stub.arrival()
        vm.zapSettleTask?.cancel()
        let settle = Task { await vm.commitZap() }
        for _ in 0..<10 { await Task.yield() }
        #expect(vm.zapLineup == nil)
        stub.release()
        await settle.value
        #expect(started == "a2")
        #expect(vm.liveChannel?.id == "a2")
        #expect(vm.zapPendingOffset == 0)
    }

    @Test func aPressAfterAFailedLoadRetriesAndTunes() async {
        let stub = LineupStub(failures: 1)
        let vm = makeViewModel(liveChannelID: "a1", zapFilter: .default, service: stub)
        var started: String?
        vm.zapStartPlayback = { started = vm.liveChannel?.id }
        vm.loadZapLineupIfNeeded()
        let failed = vm.zapLineupTask
        _ = await failed?.value
        #expect(vm.zapLineup == nil)
        vm.requestZap(by: -1)
        vm.zapSettleTask?.cancel()
        await vm.commitZap()
        #expect(started == "a0")
        #expect(vm.liveChannel?.id == "a0")
    }
}

/// Default filter: "a0"..."a4". Favorites: "f0", "f1". Optionally holds the first page until released.
private final class LineupStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var gateArmed: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var failuresLeft: Int
    private var arrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?

    init(holdFirstPage: Bool = false, fails: Bool = false, failures: Int = 0) {
        self.gateArmed = holdFirstPage
        self.failuresLeft = fails ? .max : failures
    }

    /// Returns once the held first page has been requested.
    func arrival() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if arrived { return true }
                arrivalWaiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }

    private func page(_ prefix: String, count: Int) -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(
            items: (0..<count).map {
                JellyfinChannel(id: "\(prefix)\($0)", name: "\(prefix)\($0)", channelNumber: nil,
                                imageTags: nil, currentProgram: nil, userData: nil)
            },
            totalRecordCount: nil)
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        let fail = lock.withLock { () -> Bool in
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
        if fail { throw URLError(.timedOut) }
        if filter.favoritesOnly { return page("f", count: 2) }
        let hold = lock.withLock { () -> Bool in
            defer { gateArmed = false }
            return gateArmed
        }
        if hold {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                arrived = true
                defer { arrivalWaiter = nil }
                return arrivalWaiter
            }
            waiter?.resume()
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return page("a", count: 5)
    }

    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
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
