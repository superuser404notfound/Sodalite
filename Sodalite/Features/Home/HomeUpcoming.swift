import Foundation

/// The Upcoming row (Sodalite#198): the next announced episode of every show the profile is caught
/// up on. The selection rules live here, apart from `HomeViewModel`, so they are testable without a
/// server.
///
/// Two sources. The library's own schedule comes first: Jellyfin lists announced episodes as virtual
/// items, but only when a metadata plugin creates them (the TVDB plugin's missing-episode provider),
/// so on most servers that list is empty. For a show it has nothing for, Seerr's TMDB data names the
/// next episode instead.
nonisolated enum HomeUpcoming {
    static let limit = 16
    /// How many recently watched shows are considered. Also the ceiling on Seerr lookups per load.
    static let seriesCap = 20
    /// The schedule is the whole library's, read before it is matched to the caught-up shows, so it
    /// is fetched wide and slim; the few episodes that make the row are fetched again with artwork.
    static let scheduleLimit = 1000
    /// How long a Seerr answer is reused. Air dates move rarely, and a Home refetch should not cost a
    /// round of lookups.
    static let lookupLifetime: TimeInterval = 6 * 60 * 60

    struct CachedAiring: Sendable {
        let episode: SeerrEpisode?
        let fetchedAt: Date
    }

    /// Watched episodes, newest first. Only `SeriesId` is read, which every item carries.
    static func recentlyPlayedQuery() -> ItemQuery {
        ItemQuery(
            includeItemTypes: [.episode],
            sortBy: "DatePlayed",
            sortOrder: "Descending",
            limit: 200,
            filters: ["IsPlayed"],
            fields: ""
        )
    }

    /// What `/Shows/Upcoming` asks the server for: episodes from yesterday on, soonest first.
    static func scheduleQuery(now: Date, limit: Int) -> ItemQuery {
        ItemQuery(
            includeItemTypes: [.episode],
            sortBy: "PremiereDate,SortName",
            sortOrder: "Ascending",
            limit: limit,
            minPremiereDate: now.addingTimeInterval(-24 * 60 * 60),
            fields: ""
        )
    }

    /// Shows the profile has watched and has nothing left of: Next Up names an episode for every
    /// show that still has an aired one waiting, so a watched show missing from it is caught up.
    /// Most recently watched first.
    static func caughtUpSeries(recentlyPlayed: [JellyfinItem], nextUp: [JellyfinItem]) -> [String] {
        let behind = Set(nextUp.compactMap(\.seriesId))
        var seen = Set<String>()
        let caughtUp = recentlyPlayed
            .compactMap(\.seriesId)
            .filter { !behind.contains($0) && seen.insert($0).inserted }
        return Array(caughtUp.prefix(seriesCap))
    }

    /// The calendar day an air date names. An air date is a date, not an instant: Jellyfin stores it
    /// as UTC midnight and Seerr sends `yyyy-MM-dd`, so the day is read off the string and never
    /// shifted into the viewer's time zone (west of UTC that would show every episode a day early).
    static func airDay(_ premiereDate: String?) -> DateComponents? {
        guard let premiereDate, premiereDate.count >= 10 else { return nil }
        let parts = premiereDate.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Whole days from today to the air day, negative once it has aired.
    static func daysUntil(_ premiereDate: String?, now: Date, calendar: Calendar) -> Int? {
        guard let components = airDay(premiereDate), let airDate = calendar.date(from: components) else { return nil }
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: airDate)
        ).day
    }

    /// The soonest unwatched, not yet aired episode of each caught-up show. `schedule` arrives
    /// soonest first, so the first hit per show is its next one.
    static func fromLibrary(
        _ schedule: [JellyfinItem], caughtUp: [String], now: Date, calendar: Calendar
    ) -> [JellyfinItem] {
        let wanted = Set(caughtUp)
        var seen = Set<String>()
        return schedule.filter { item in
            guard item.type == .episode,
                  let seriesID = item.seriesId, wanted.contains(seriesID),
                  item.userData?.played != true,
                  let days = daysUntil(item.premiereDate, now: now, calendar: calendar), days >= 0
            else { return false }
            return seen.insert(seriesID).inserted
        }
    }

    /// The caught-up shows the library had nothing for, which are the ones worth a Seerr lookup.
    static func needingLookup(caughtUp: [String], found: [JellyfinItem]) -> [String] {
        let covered = Set(found.compactMap(\.seriesId))
        return caughtUp.filter { !covered.contains($0) }
    }

    /// A show is looked up when TMDB knows it and it has not ended. A missing status still counts:
    /// an ended show simply comes back without a next episode.
    static func isLookupCandidate(_ series: JellyfinItem) -> Bool {
        guard series.tmdbID != nil else { return false }
        return series.status?.caseInsensitiveCompare("Ended") != .orderedSame
    }

    /// Seerr's next episode as a card, nil when there is none or its date has passed (TMDB keeps
    /// naming an aired episode as next until its data is refreshed).
    static func fromSeerr(
        series: JellyfinItem, episode: SeerrEpisode?, now: Date, calendar: Calendar
    ) -> JellyfinItem? {
        guard let episode, let airDate = episode.airDate,
              let days = daysUntil(airDate, now: now, calendar: calendar), days >= 0
        else { return nil }
        return JellyfinItem(
            upcomingEpisodeOf: series,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            name: episode.name,
            airDate: airDate
        )
    }

    /// Soonest first, ties by show name, capped to the row's length.
    static func ordered(_ items: [JellyfinItem]) -> [JellyfinItem] {
        let sorted = items.sorted { lhs, rhs in
            let l = lhs.premiereDate.map { String($0.prefix(10)) } ?? ""
            let r = rhs.premiereDate.map { String($0.prefix(10)) } ?? ""
            if l != r { return l < r }
            return (lhs.seriesName ?? "").localizedStandardCompare(rhs.seriesName ?? "") == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }

    /// The card's pill: "Today", "Tomorrow", "In 3 days" for the coming week, a short date after
    /// that. Foundation words it in every locale, so none of it lives in the string catalog.
    static func badge(for premiereDate: String?, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard let components = airDay(premiereDate),
              let airDate = calendar.date(from: components),
              let days = daysUntil(premiereDate, now: now, calendar: calendar), days >= 0
        else { return nil }
        let text: String
        if days < 7 {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            formatter.calendar = calendar
            formatter.locale = locale
            text = formatter.localizedString(from: DateComponents(day: days))
        } else {
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            text = airDate.formatted(style.locale(locale))
        }
        guard let first = text.first else { return nil }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }
}
