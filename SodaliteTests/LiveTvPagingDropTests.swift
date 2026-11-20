import Testing
import Foundation
@testable import Sodalite

/// A page where `LossyList` dropped an element is still a full page for the pagers (audit FR-DAT-1).
@MainActor
struct LiveTvPagingDropTests {

    @Test func aDecodedPageCountsItsDroppedElement() throws {
        let json = #"{"Items":[{"Id":"a","Name":"A"},{"Name":"no id"},{"Id":"c","Name":"C"}],"TotalRecordCount":3}"#
        let page = try JSONDecoder.jellyfinLiveTv.decode(LiveTvChannelsResponse.self, from: Data(json.utf8))
        #expect(page.items.count == 2)
        #expect(page.dropped == 1)
        #expect(page.pageCount == 3)
    }

    @Test func theGuideLineupAsksForTheNextPageAtTheRawOffset() async {
        let service = PagingStub(total: 450, dropOnFirstPage: true)
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        #expect(service.starts == [0, 200, 400])
        #expect(model.channels.count == 449)
    }

    @Test func theZapLineupDoesNotEndOnAShortPage() async throws {
        let service = PagingStub(total: 450, dropOnFirstPage: true)
        let result = await PlayerViewModel.fetchLineup(service: service, userID: "u", filter: .default)
        let lineup = try result.get()
        #expect(service.starts == [0, 200, 400])
        #expect(lineup.channels.count == 449)
    }
}

private final class PagingStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts: [Int] = []
    let total: Int
    let dropOnFirstPage: Bool
    init(total: Int, dropOnFirstPage: Bool) { self.total = total; self.dropOnFirstPage = dropOnFirstPage }
    var starts: [Int] { lock.withLock { _starts } }

    func getChannels(userID: String, startIndex: Int, limit: Int, filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        if limit == 1 { return LiveTvChannelsResponse(items: [], totalRecordCount: 0) }
        lock.withLock { _starts.append(startIndex) }
        let end = min(startIndex + limit, total)
        var ids = Array(startIndex..<max(startIndex, end))
        var dropped = 0
        if dropOnFirstPage && startIndex == 0 { ids.removeLast(); dropped = 1 }
        return LiveTvChannelsResponse(
            items: ids.map { JellyfinChannel(id: "c\($0)", name: "c\($0)", channelNumber: nil,
                                             imageTags: nil, currentProgram: nil, userData: nil) },
            totalRecordCount: total, dropped: dropped)
    }

    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
    func getProgramIndex(userID: String, window: GuideProgramWindow, genres: String?, category: GuideFilter.Category?, cap: Int) async throws -> [JellyfinProgram] { [] }
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
