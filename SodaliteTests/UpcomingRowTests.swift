import Foundation
import Testing
@testable import Sodalite

/// Sodalite#198: the Upcoming row's selection rules, its date handling and its two sources.
@MainActor
struct UpcomingRowTests {
    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func episode(_ id: String, series: String, date: String? = nil, played: Bool = false) throws -> JellyfinItem {
        let premiere = date.map { #","PremiereDate":"\#($0)T00:00:00.0000000Z""# } ?? ""
        return try item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"\#(series)","SeriesName":"Show \#(series)","UserData":{"Played":\#(played)}\#(premiere)}"#)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ string: String, hour: Int = 12, calendar: Calendar) -> Date {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    // MARK: - Row type

    @Test func rowIsOptInLandscape() {
        #expect(!HomeRowType.upcoming.defaultEnabled)
        #expect(HomeRowType.upcoming.cardStyle == .landscape)
        #expect(HomeRowConfig.defaultConfig().contains { $0.type == .upcoming })
        #expect(HomeRowType.upcoming.systemImage != HomeRowType.recentlyReleasedShows.systemImage)
    }

    /// A stored layout from before the row existed gets it appended, off, without a Reset.
    @Test func reconciliationAppendsTheRowDisabled() {
        let stored = HomeRowConfig.defaultConfig().filter { $0.type != .upcoming }
        let result = HomeRowConfig.reconciled(stored: stored, libraries: [])
        let row = result.first { $0.type == .upcoming }
        #expect(row?.isEnabled == false)
    }

    // MARK: - Queries

    @Test func scheduleQueryAsksForEpisodesFromYesterdaySoonestFirst() {
        let now = day("2026-10-22", calendar: utc)
        let items = HomeUpcoming.scheduleQuery(now: now, limit: 200).toQueryItems()
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("IncludeItemTypes") == "Episode")
        #expect(value("SortOrder") == "Ascending")
        #expect(value("SortBy") == "PremiereDate,SortName")
        #expect(value("MinPremiereDate") == "2026-10-21T12:00:00Z")
        #expect(value("MaxPremiereDate") == nil)
        #expect(value("IsMissing") == nil)
        #expect(value("Fields") == "")
    }

    @Test func recentlyPlayedQueryReadsWatchedEpisodesNewestFirst() {
        let items = HomeUpcoming.recentlyPlayedQuery().toQueryItems()
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("Filters") == "IsPlayed")
        #expect(value("SortBy") == "DatePlayed")
        #expect(value("SortOrder") == "Descending")
    }

    // MARK: - Caught up

    @Test func caughtUpIsWatchedMinusNextUpInWatchOrder() throws {
        let played = try [
            episode("1", series: "b"), episode("2", series: "a"), episode("3", series: "b"),
            episode("4", series: "c"),
        ]
        let nextUp = try [episode("9", series: "c")]
        #expect(HomeUpcoming.caughtUpSeries(recentlyPlayed: played, nextUp: nextUp) == ["b", "a"])
    }

    @Test func caughtUpIsCapped() throws {
        let played = try (0..<40).map { try episode("\($0)", series: "s\($0)") }
        #expect(HomeUpcoming.caughtUpSeries(recentlyPlayed: played, nextUp: []).count == HomeUpcoming.seriesCap)
    }

    // MARK: - Dates

    /// West of UTC a UTC-midnight air date is the evening before in local time; the row must still
    /// name the day the date says.
    @Test func airDayIsNotShiftedIntoTheLocalZone() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let now = day("2026-10-22", hour: 9, calendar: newYork)
        #expect(HomeUpcoming.daysUntil("2026-10-22T00:00:00.0000000Z", now: now, calendar: newYork) == 0)
        #expect(HomeUpcoming.daysUntil("2026-10-25", now: now, calendar: newYork) == 3)
        #expect(HomeUpcoming.daysUntil("2026-10-21", now: now, calendar: newYork) == -1)
        #expect(HomeUpcoming.daysUntil(nil, now: now, calendar: newYork) == nil)
        #expect(HomeUpcoming.daysUntil("soon", now: now, calendar: newYork) == nil)
    }

    @Test func badgeNamesTheDay() {
        let now = day("2026-10-22", calendar: utc)
        let english = Locale(identifier: "en_US")
        #expect(HomeUpcoming.badge(for: "2026-10-22", now: now, calendar: utc, locale: english) == "Today")
        #expect(HomeUpcoming.badge(for: "2026-10-23", now: now, calendar: utc, locale: english) == "Tomorrow")
        #expect(HomeUpcoming.badge(for: "2026-10-25", now: now, calendar: utc, locale: english) == "In 3 days")
        #expect(HomeUpcoming.badge(for: "2026-11-04", now: now, calendar: utc, locale: english) == "Nov 4")
        #expect(HomeUpcoming.badge(for: "2026-10-21", now: now, calendar: utc, locale: english) == nil)
        let german = Locale(identifier: "de_DE")
        #expect(HomeUpcoming.badge(for: "2026-10-22", now: now, calendar: utc, locale: german) == "Heute")
    }

    // MARK: - Library source

    @Test func libraryKeepsTheSoonestUnwatchedUnairedEpisodePerCaughtUpShow() throws {
        let now = day("2026-10-22", calendar: utc)
        let schedule = try [
            episode("aired", series: "a", date: "2026-10-21"),
            episode("a1", series: "a", date: "2026-10-22"),
            episode("a2", series: "a", date: "2026-10-29"),
            episode("seen", series: "b", date: "2026-10-23", played: true),
            episode("b1", series: "b", date: "2026-10-30"),
            episode("other", series: "z", date: "2026-10-23"),
        ]
        let found = HomeUpcoming.fromLibrary(schedule, caughtUp: ["a", "b"], now: now, calendar: utc)
        #expect(found.map(\.id) == ["a1", "b1"])
        #expect(HomeUpcoming.needingLookup(caughtUp: ["a", "b", "c"], found: found) == ["c"])
    }

    // MARK: - Seerr source

    @Test func seerrEpisodeBecomesAVirtualCardOfItsShow() throws {
        let series = try item(#"{"Id":"s1","Name":"Nobody Wants This","Type":"Series","ServerId":"srv","BackdropImageTags":["bd"],"ImageTags":{"Primary":"pr"},"ProviderIds":{"Tmdb":"1"}}"#)
        let episode = SeerrEpisode(
            id: 7, episodeNumber: 1, seasonNumber: 3, name: "Pilot", overview: nil,
            stillPath: nil, airDate: "2026-10-25", voteAverage: nil, runtime: nil
        )
        let now = day("2026-10-22", calendar: utc)
        let card = try #require(HomeUpcoming.fromSeerr(series: series, episode: episode, now: now, calendar: utc))
        #expect(card.type == .episode)
        #expect(card.isVirtual)
        #expect(card.seriesId == "s1")
        #expect(card.seriesName == "Nobody Wants This")
        #expect(card.parentIndexNumber == 3)
        #expect(card.indexNumber == 1)
        #expect(card.premiereDate == "2026-10-25")
        #expect(card.serverID == "srv")
        #expect(card.parentBackdropImageTags == ["bd"])
        #expect(card.seriesPrimaryImageTag == "pr")
        #expect(card.id != series.id)

        let aired = SeerrEpisode(
            id: 8, episodeNumber: 2, seasonNumber: 3, name: nil, overview: nil,
            stillPath: nil, airDate: "2026-10-20", voteAverage: nil, runtime: nil
        )
        #expect(HomeUpcoming.fromSeerr(series: series, episode: aired, now: now, calendar: utc) == nil)
        #expect(HomeUpcoming.fromSeerr(series: series, episode: nil, now: now, calendar: utc) == nil)
    }

    @Test func onlyRunningShowsWithATmdbIdAreLookedUp() throws {
        let running = try item(#"{"Id":"a","Name":"A","Type":"Series","Status":"Continuing","ProviderIds":{"Tmdb":"1"}}"#)
        let unknown = try item(#"{"Id":"b","Name":"B","Type":"Series","ProviderIds":{"Tmdb":"2"}}"#)
        let ended = try item(#"{"Id":"c","Name":"C","Type":"Series","Status":"Ended","ProviderIds":{"Tmdb":"3"}}"#)
        let tvdbOnly = try item(#"{"Id":"d","Name":"D","Type":"Series","ProviderIds":{"Tvdb":"4"}}"#)
        #expect(HomeUpcoming.isLookupCandidate(running))
        #expect(HomeUpcoming.isLookupCandidate(unknown))
        #expect(!HomeUpcoming.isLookupCandidate(ended))
        #expect(!HomeUpcoming.isLookupCandidate(tvdbOnly))
    }

    @Test func seerrDetailDecodesNextEpisodeToAir() throws {
        let json = #"{"id":1,"name":"Show","nextEpisodeToAir":{"id":5,"episodeNumber":2,"seasonNumber":4,"airDate":"2026-11-01","name":"Two"}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(SeerrTVDetail.self, from: Data(json.utf8))
        #expect(detail.nextEpisodeToAir?.seasonNumber == 4)
        #expect(detail.nextEpisodeToAir?.airDate == "2026-11-01")
    }

    // MARK: - Order

    @Test func rowIsSoonestFirstAcrossBothSources() throws {
        let items = try [
            episode("late", series: "a", date: "2026-11-01"),
            episode("soon", series: "b", date: "2026-10-23"),
            item(#"{"Id":"mid","Name":"m","Type":"Episode","SeriesId":"c","SeriesName":"C","PremiereDate":"2026-10-25"}"#),
        ]
        #expect(HomeUpcoming.ordered(items).map(\.id) == ["soon", "mid", "late"])
    }

    @Test func mergedRowStaysSoonestFirst() throws {
        let a = try [episode("a1", series: "a", date: "2026-10-30")]
        let b = try [episode("b1", series: "b", date: "2026-10-23")]
        let merged = HomeMerger.merge([a, b], type: .upcoming, mergedContinueWatching: false)
        #expect(merged.map(\.id) == ["b1", "a1"])
    }
}
