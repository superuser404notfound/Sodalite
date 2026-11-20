import Testing
import Foundation
@testable import Sodalite

/// #201: the category chips answer "what airs now" through the program query, and the Radio chip
/// follows the channels' own ChannelType, because Jellyfin's channel filters do neither.
@MainActor
struct GuideCategoryChipTests {

    private func value(_ items: [URLQueryItem]?, _ name: String) -> String? {
        items?.first(where: { $0.name == name })?.value
    }

    @Test func theCategoryIndexAsksForTheProgramFlagAiringNow() {
        let items = JellyfinEndpoint.liveTvProgramIndex(
            userID: "u", window: .airing, genres: nil, category: .news,
            startIndex: 0, limit: 500).queryItems
        #expect(value(items, "IsAiring") == "true")
        #expect(value(items, "IsNews") == "true")
        #expect(value(items, "Genres") == nil)
    }

    @Test func aCategoryNarrowsTheGuideToChannelsAiringIt() async {
        let service = CategoryStub()
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        #expect(model.channels.map(\.id) == ["c0", "c1"])
        let fetches = service.channelFetches

        var filter = model.filter
        filter.category = .sports
        await model.apply(filter: filter)
        #expect(model.channels.map(\.id) == ["c1"])
        #expect(service.lastCategory == .sports)
        #expect(service.lastWindowWasAiring == true)
        #expect(!model.categories.isResolving)
        // The channel list did not change, only what is drawn from it.
        #expect(service.channelFetches == fetches)

        filter.category = nil
        await model.apply(filter: filter)
        #expect(model.channels.map(\.id) == ["c0", "c1"])
    }

    @Test func theRadioChipFollowsTheChannelsNotAProbe() async {
        let service = CategoryStub()
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        #expect(model.hasRadioChannels)
        var filter = model.filter
        filter.kind = .radio
        await model.apply(filter: filter)
        #expect(model.channels.map(\.id) == ["r0"])
    }

    @Test func aServerWithoutRadioChannelsOffersNoRadioChip() async {
        let service = CategoryStub()
        service.hasRadio = false
        let model = ChannelListViewModel(service: service, userID: "u",
                                         timers: LiveTimerStore(service: service, userID: "u"))
        await model.load()
        #expect(!model.hasRadioChannels)
        #expect(model.channels.map(\.id) == ["c0", "c1"])
    }

    @Test func theIPhoneListNarrowsByCategoryTheSameWay() async {
        let service = CategoryStub()
        let model = ChannelListViewModel(service: service, userID: "u",
                                         timers: LiveTimerStore(service: service, userID: "u"))
        await model.load()
        var filter = model.filter
        filter.category = .sports
        await model.apply(filter: filter)
        #expect(model.channels.map(\.id) == ["c1"])
    }
}

/// c0 and c1 are TV (c0 without a type, like an M3U channel), r0 is radio. Airing now: c1 a Sports
/// program. The channel list ignores every filter, as Jellyfin's does.
private final class CategoryStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var category: GuideFilter.Category?
    private var airing: Bool?
    private var fetches = 0
    var hasRadio = true

    var lastCategory: GuideFilter.Category? { lock.withLock { category } }
    var lastWindowWasAiring: Bool? { lock.withLock { airing } }
    var channelFetches: Int { lock.withLock { fetches } }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        lock.withLock { fetches += 1 }
        var items = [
            JellyfinChannel(id: "c0", name: "c0", channelNumber: nil, imageTags: nil,
                            currentProgram: nil, userData: nil),
            JellyfinChannel(id: "c1", name: "c1", channelNumber: nil, imageTags: nil,
                            currentProgram: nil, userData: nil, channelType: "TV"),
        ]
        if hasRadio {
            items.append(JellyfinChannel(id: "r0", name: "r0", channelNumber: nil, imageTags: nil,
                                         currentProgram: nil, userData: nil, channelType: "Radio"))
        }
        return LiveTvChannelsResponse(items: items, totalRecordCount: items.count)
    }

    func getProgramIndex(userID: String, window: GuideProgramWindow, genres: String?,
                         category: GuideFilter.Category?, cap: Int) async throws -> [JellyfinProgram] {
        lock.withLock {
            self.category = category
            airing = window == .airing
        }
        guard category == .sports else { return [] }
        return [JellyfinProgram(
            id: "p1", channelId: "c1", channelName: nil, name: "p1", overview: nil,
            startDate: nil, endDate: nil,
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: true, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)]
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
