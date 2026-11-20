import Testing
import Foundation
@testable import Sodalite

/// Sodalite#182: the guide's genre narrowing. Jellyfin filters programs, not channels, by genre, so
/// the matching channels come from a program query and a wrong parameter fails silently (the server
/// ignores it and answers with every program).
@MainActor
struct GuideGenreFilterTests {

    private func program(_ id: String, channel: String, genres: [String]?) -> JellyfinProgram {
        JellyfinProgram(
            id: id, channelId: channel, channelName: nil, name: id, overview: nil,
            startDate: nil, endDate: nil,
            genres: genres, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    private func value(_ items: [URLQueryItem]?, _ name: String) -> String? {
        items?.first(where: { $0.name == name })?.value
    }

    // MARK: - Matching

    @Test func anInactiveFilterMatchesEverything() {
        #expect(GuideGenreFilter().matches(program("p", channel: "c", genres: nil)))
    }

    @Test func matchingIgnoresCaseAndDiacriticsLikeTheServer() {
        let filter = GuideGenreFilter(genres: ["Comédie"])
        #expect(filter.matches(program("p", channel: "c", genres: ["comedie"])))
        #expect(!filter.matches(program("q", channel: "c", genres: ["News"])))
        #expect(!filter.matches(program("r", channel: "c", genres: nil)))
    }

    @Test func severalGenresCombineAsOr() {
        let filter = GuideGenreFilter(genres: ["NFL", "NBA"])
        #expect(filter.queryValue == "NBA|NFL")
        #expect(filter.matches(program("p", channel: "c", genres: ["NBA"])))
    }

    @Test func theGenreListIsDistinctSortedAndPipeFree() {
        let names = GuideGenreFilter.genreNames(in: [
            program("a", channel: "c", genres: ["Sports", "NFL", " "]),
            program("b", channel: "c", genres: ["sports", "Animation", "A|B"]),
            program("c", channel: "c", genres: nil),
        ])
        #expect(names == ["Animation", "NFL", "Sports"])
    }

    @Test func theChipNamesTheFirstGenreAndCountsTheRest() {
        #expect(GuideGenreFilter().chipLabel == nil)
        #expect(GuideGenreFilter(genres: ["NFL"]).chipLabel == "NFL")
        #expect(GuideGenreFilter(genres: ["NFL", "NBA", "MLB"]).chipLabel == "MLB +2")
    }

    @Test func doublyEscapedEPGTextIsDecodedForDisplayOnly() {
        #expect("Food &amp; Cooking".epgDisplayText == "Food & Cooking")
        #expect("Rock &amp;amp; Roll".epgDisplayText == "Rock & Roll")
        #expect("Caf&#233; &#x26; Bar".epgDisplayText == "Café & Bar")
        #expect("Tom & Jerry".epgDisplayText == "Tom & Jerry")
        #expect("A &bogus; B".epgDisplayText == "A &bogus; B")
        let filter = GuideGenreFilter(genres: ["Food &amp; Cooking"])
        #expect(filter.chipLabel == "Food & Cooking")
        #expect(filter.queryValue == "Food &amp; Cooking")
    }

    // MARK: - Query

    @Test func theAiringIndexAsksForWhatIsOnNow() {
        let endpoint = JellyfinEndpoint.liveTvProgramIndex(
            userID: "u", window: .airing, genres: "NBA|NFL", category: nil, startIndex: 500, limit: 500)
        let items = endpoint.queryItems
        #expect(endpoint.path == "/LiveTv/Programs")
        #expect(value(items, "IsAiring") == "true")
        #expect(value(items, "MinEndDate") == nil)
        #expect(value(items, "Genres") == "NBA|NFL")
        #expect(value(items, "StartIndex") == "500")
        #expect(value(items, "EnableImages") == "false")
        #expect(value(items, "Fields") == "Genres")
    }

    @Test func theWindowIndexOverlapsTheWindowAndSendsNoGenresForTheList() {
        let items = JellyfinEndpoint.liveTvProgramIndex(
            userID: "u",
            window: .range(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600)),
            genres: nil, category: nil, startIndex: 0, limit: 500).queryItems
        #expect(value(items, "IsAiring") == nil)
        #expect(value(items, "MinEndDate") != nil)
        #expect(value(items, "MaxStartDate") != nil)
        #expect(value(items, "Genres") == nil)
    }

    @Test func gridProgramsCarryTheirGenresForDimming() {
        let fields = value(JellyfinEndpoint.liveTvPrograms(
            channelIDs: ["c"], userID: "u",
            minEndDate: Date(timeIntervalSince1970: 0),
            maxStartDate: Date(timeIntervalSince1970: 3600)).queryItems, "Fields")
        #expect(fields?.split(separator: ",").contains("Genres") == true)
    }

    // MARK: - View model

    @Test func aGenreNarrowsTheGuideToChannelsAiringIt() async {
        let service = GenreStub()
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        #expect(model.channels.map(\.id) == ["c0", "c1", "c2"])

        await model.genres.apply(GuideGenreFilter(genres: ["NFL"], scope: .guide))
        #expect(model.channels.map(\.id) == ["c1"])
        #expect(service.lastGenres == "NFL")
        #expect(service.lastWindowWasAiring == false)
        #expect(!model.genres.isResolving)

        await model.genres.apply(GuideGenreFilter(scope: .guide))
        #expect(model.channels.map(\.id) == ["c0", "c1", "c2"])
    }

    @Test func theSearchStillNarrowsInsideAGenre() async {
        let service = GenreStub()
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        await model.genres.apply(GuideGenreFilter(genres: ["NFL", "Comedy"]))
        #expect(service.lastWindowWasAiring == true)
        #expect(model.channels.map(\.id) == ["c1", "c2"])
        model.apply(searchText: "c2")
        #expect(model.channels.map(\.id) == ["c2"])
    }

    /// An empty grid would read as "nothing matches". A failed match drops the selection instead.
    @Test func aFailedMatchDropsTheSelectionRatherThanEmptyingTheGrid() async {
        let service = GenreStub()
        service.failIndex = true
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.load()
        await model.genres.apply(GuideGenreFilter(genres: ["NFL"]))
        #expect(!model.genres.filter.isActive)
        #expect(model.genres.error != nil)
        #expect(model.channels.map(\.id) == ["c0", "c1", "c2"])
    }

    @Test func theIPhoneListNarrowsTheSameWay() async {
        let service = GenreStub()
        let model = ChannelListViewModel(service: service, userID: "u",
                                         timers: LiveTimerStore(service: service, userID: "u"))
        await model.load()
        #expect(model.channels.map(\.id) == ["c0", "c1", "c2"])
        await model.genres.apply(GuideGenreFilter(genres: ["Comedy"], scope: .guide))
        #expect(model.channels.map(\.id) == ["c2"])
        #expect(service.lastWindowWasAiring == false)
        await model.genres.apply(GuideGenreFilter(scope: .guide))
        #expect(model.channels.map(\.id) == ["c0", "c1", "c2"])
    }

    @Test func theGenreListComesFromTheProgramsInScope() async {
        let service = GenreStub()
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        await model.genres.loadNames(for: .now)
        #expect(model.genres.names[.now] == ["Comedy", "NFL", "Sports"])
        #expect(service.lastGenres == nil)
    }
}

/// Three channels. Program index: c1 airs NFL (also tagged Sports), c2 airs Comedy, c0 has no genres.
private final class GenreStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var genres: String?
    private var airing: Bool?
    var failIndex = false

    var lastGenres: String? { lock.withLock { genres } }
    var lastWindowWasAiring: Bool? { lock.withLock { airing } }

    private let programs: [JellyfinProgram] = [
        ("p0", "c0", nil), ("p1", "c1", ["NFL", "Sports"]), ("p2", "c2", ["Comedy"]),
    ].map { id, channel, genres in
        JellyfinProgram(
            id: id, channelId: channel, channelName: nil, name: id, overview: nil,
            startDate: nil, endDate: nil,
            genres: genres, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
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
            totalRecordCount: 3)
    }

    func getProgramIndex(userID: String, window: GuideProgramWindow, genres: String?,
                         category: GuideFilter.Category?, cap: Int) async throws -> [JellyfinProgram] {
        lock.withLock {
            self.genres = genres
            airing = window == .airing
        }
        if failIndex && genres != nil { throw URLError(.timedOut) }
        guard let genres else { return programs }
        let wanted = Set(genres.split(separator: "|").map { $0.lowercased() })
        return programs.filter { ($0.genres ?? []).contains { wanted.contains($0.lowercased()) } }
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
