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
        vm.zapSettleTask?.cancel()
    }
}

/// Default filter: "a0"..."a4". Favorites: "f0", "f1". Optionally holds the first page until released.
private final class LineupStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var gateArmed: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private let fails: Bool

    init(holdFirstPage: Bool = false, fails: Bool = false) {
        self.gateArmed = holdFirstPage
        self.fails = fails
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
        if fails { throw URLError(.timedOut) }
        if filter.favoritesOnly { return page("f", count: 2) }
        let hold = lock.withLock { () -> Bool in
            defer { gateArmed = false }
            return gateArmed
        }
        if hold {
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
