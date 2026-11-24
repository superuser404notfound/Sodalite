import SwiftUI

// The filter menu of the library grids (Sodalite#252), the groups Jellyfin web offers. It sits next
// to the watch control and ANDs with it: Unwatched plus Horror plus 1999 is unwatched horror from
// 1999. Several values inside one group match any of them, except where the server only has
// separate yes/no parameters (Features, and 3D next to a resolution), which can only all match.

/// The menu's groups, in the order they are listed.
enum LibraryFilterGroup: String, CaseIterable, Hashable, Identifiable, Sendable {
    case filters
    case features
    case videoType
    case genres
    case parentalRatings
    case tags
    case years
    case studios
    case audioLanguages
    case subtitleLanguages
    case seriesStatus

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .filters: "library.filter.group.filters"
        case .features: "library.filter.group.features"
        case .videoType: "library.filter.group.videoType"
        case .genres: "library.filter.group.genres"
        case .parentalRatings: "library.filter.group.parentalRatings"
        case .tags: "library.filter.group.tags"
        case .years: "library.filter.group.years"
        case .studios: "library.filter.group.studios"
        case .audioLanguages: "library.filter.group.audioLanguages"
        case .subtitleLanguages: "library.filter.group.subtitleLanguages"
        case .seriesStatus: "library.filter.group.seriesStatus"
        }
    }

    /// Fixed lists that need no server answer.
    var isFixed: Bool {
        switch self {
        case .filters, .features, .videoType, .seriesStatus: true
        default: false
        }
    }
}

/// Played and Unplayed stay on the watch control, so this group only has the other two `Filters`.
enum LibraryStateFilter: String, CaseIterable, Hashable, Sendable {
    case favorites
    case continueWatching

    var jellyfinFilter: String {
        switch self {
        case .favorites: "IsFavorite"
        case .continueWatching: "IsResumable"
        }
    }

    var titleKey: String {
        switch self {
        case .favorites: "library.filter.favorites"
        case .continueWatching: "library.filter.continueWatching"
        }
    }
}

enum LibraryFeatureFilter: String, CaseIterable, Hashable, Sendable {
    case subtitles
    case trailers
    case extras
    case themeSongs
    case themeVideos

    var titleKey: String {
        switch self {
        case .subtitles: "library.filter.feature.subtitles"
        case .trailers: "library.filter.feature.trailers"
        case .extras: "library.filter.feature.extras"
        case .themeSongs: "library.filter.feature.themeSongs"
        case .themeVideos: "library.filter.feature.themeVideos"
        }
    }
}

enum LibraryVideoTypeFilter: String, CaseIterable, Hashable, Sendable {
    case sd
    case hd
    case uhd
    case threeD
    case dvd
    case bluRay
    case iso

    /// Not translated: these are the labels on the discs and the boxes in every language.
    var label: String {
        switch self {
        case .sd: "SD"
        case .hd: "HD"
        case .uhd: "4K"
        case .threeD: "3D"
        case .dvd: "DVD"
        case .bluRay: "Blu-ray"
        case .iso: "ISO"
        }
    }

    /// SD, HD and 4K are one choice. The server has `IsHd=true/false` and a separate `Is4K`, and
    /// counts a 4K file as neither SD nor HD, so two of them together could only ever match nothing.
    var isResolution: Bool { self == .sd || self == .hd || self == .uhd }

    /// The `VideoTypes` value of a disc kind; the three share one parameter and match any.
    var jellyfinVideoType: String? {
        switch self {
        case .dvd: "Dvd"
        case .bluRay: "BluRay"
        case .iso: "Iso"
        default: nil
        }
    }
}

enum LibrarySeriesStatusFilter: String, CaseIterable, Hashable, Sendable {
    case continuing
    case ended
    case unreleased

    var jellyfinValue: String {
        switch self {
        case .continuing: "Continuing"
        case .ended: "Ended"
        case .unreleased: "Unreleased"
        }
    }

    var titleKey: String {
        switch self {
        case .continuing: "library.filter.seriesStatus.continuing"
        case .ended: "library.filter.seriesStatus.ended"
        case .unreleased: "library.filter.seriesStatus.unreleased"
        }
    }
}

/// A language the server lists: `name` is shown, `value` is sent.
struct LanguageFacet: Hashable, Sendable {
    let name: String
    let value: String
}

/// One server's answer for one grid. Genres and studios are picked by name and sent by id, and the
/// ids belong to this server only, which is why a combined grid keeps one of these per server.
struct ServerFacets: Sendable, Equatable {
    var genres: [String] = []
    /// Lowercased name to id, from `/Items/Filters2`. Empty on a server that does not have it.
    var genreIDs: [String: String] = [:]
    var officialRatings: [String] = []
    var tags: [String] = []
    var years: [Int] = []
    var studios: [String] = []
    /// Lowercased name to id, from `/Studios`.
    var studioIDs: [String: String] = [:]
    var audioLanguages: [LanguageFacet] = []
    var subtitleLanguages: [LanguageFacet] = []
}

/// What a grid's menu lists: every server's facets joined, plus each server's ids.
struct LibraryFacets: Sendable, Equatable {
    var genres: [String] = []
    var officialRatings: [String] = []
    var tags: [String] = []
    var years: [Int] = []
    var studios: [String] = []
    var audioLanguages: [LanguageFacet] = []
    var subtitleLanguages: [LanguageFacet] = []
    /// By server id. A server missing here did not answer, see `LibraryFilterSelection.applied`.
    var byServer: [String: ServerFacets] = [:]

    /// Names compare case-insensitively, the way Jellyfin matches them; the first spelling wins.
    /// Years run newest first, like the web client's list.
    static func merge(_ servers: [(serverID: String, facets: ServerFacets)]) -> LibraryFacets {
        var merged = LibraryFacets()
        merged.genres = joinNames(servers.map(\.facets.genres))
        merged.officialRatings = joinNames(servers.map(\.facets.officialRatings))
        merged.tags = joinNames(servers.map(\.facets.tags))
        merged.studios = joinNames(servers.map(\.facets.studios))
        merged.years = Array(Set(servers.flatMap(\.facets.years))).sorted(by: >)
        merged.audioLanguages = joinLanguages(servers.map(\.facets.audioLanguages))
        merged.subtitleLanguages = joinLanguages(servers.map(\.facets.subtitleLanguages))
        for server in servers { merged.byServer[server.serverID] = server.facets }
        return merged
    }

    private static func joinNames(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in lists.joined() where !name.isEmpty && seen.insert(name.lowercased()).inserted {
            names.append(name)
        }
        guard lists.count > 1 else { return names }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func joinLanguages(_ lists: [[LanguageFacet]]) -> [LanguageFacet] {
        var seen = Set<String>()
        var languages: [LanguageFacet] = []
        for language in lists.joined() where seen.insert(language.value.lowercased()).inserted {
            languages.append(language)
        }
        guard lists.count > 1 else { return languages }
        return languages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// What the grid narrows by on top of its own query. Equatable so it can join the grid's
/// `ReloadKey`, which is what makes the alphabet rail and the cache see it.
struct LibraryFilterSelection: Hashable, Sendable {
    var states: Set<LibraryStateFilter> = []
    var features: Set<LibraryFeatureFilter> = []
    var videoTypes: Set<LibraryVideoTypeFilter> = []
    var genres: Set<String> = []
    var officialRatings: Set<String> = []
    var tags: Set<String> = []
    var years: Set<Int> = []
    var studios: Set<String> = []
    /// Language codes (`LanguageFacet.value`).
    var audioLanguages: Set<String> = []
    var subtitleLanguages: Set<String> = []
    var seriesStatus: Set<LibrarySeriesStatusFilter> = []

    var isEmpty: Bool { activeCount == 0 }

    var activeCount: Int {
        states.count + features.count + videoTypes.count + genres.count + officialRatings.count
            + tags.count + years.count + studios.count + audioLanguages.count
            + subtitleLanguages.count + seriesStatus.count
    }

    func count(in group: LibraryFilterGroup) -> Int {
        switch group {
        case .filters: states.count
        case .features: features.count
        case .videoType: videoTypes.count
        case .genres: genres.count
        case .parentalRatings: officialRatings.count
        case .tags: tags.count
        case .years: years.count
        case .studios: studios.count
        case .audioLanguages: audioLanguages.count
        case .subtitleLanguages: subtitleLanguages.count
        case .seriesStatus: seriesStatus.count
        }
    }

    mutating func clear(_ group: LibraryFilterGroup) {
        switch group {
        case .filters: states = []
        case .features: features = []
        case .videoType: videoTypes = []
        case .genres: genres = []
        case .parentalRatings: officialRatings = []
        case .tags: tags = []
        case .years: years = []
        case .studios: studios = []
        case .audioLanguages: audioLanguages = []
        case .subtitleLanguages: subtitleLanguages = []
        case .seriesStatus: seriesStatus = []
        }
    }

    /// A resolution replaces the one picked before (see `LibraryVideoTypeFilter.isResolution`).
    mutating func toggle(_ videoType: LibraryVideoTypeFilter) {
        if videoTypes.remove(videoType) != nil { return }
        if videoType.isResolution { videoTypes = videoTypes.filter { !$0.isResolution } }
        videoTypes.insert(videoType)
    }

    /// The menu's `Filters` values, which join whatever the grid already sends there.
    var jellyfinFilters: [String] {
        LibraryStateFilter.allCases.filter(states.contains).map(\.jellyfinFilter)
    }

    /// `query` narrowed for one server, or nil when that server cannot hold a single match: every
    /// genre or studio picked is missing from its library, and leaving the parameter off would
    /// widen the grid instead.
    ///
    /// `facets` nil (the server did not answer the facet calls) falls back to names, which only
    /// works where the grid does not constrain that axis itself: `Genres` names OR with a genre
    /// tile's own genre, and `Studios` names replace a studio tile's.
    func applied(to query: ItemQuery, facets: ServerFacets?) -> ItemQuery? {
        var narrowed = query
        let filters = (query.filters ?? []) + jellyfinFilters.filter { !(query.filters ?? []).contains($0) }
        narrowed.filters = filters.isEmpty ? nil : filters

        if !features.isEmpty {
            if features.contains(.subtitles) { narrowed.hasSubtitles = true }
            if features.contains(.trailers) { narrowed.hasTrailer = true }
            if features.contains(.extras) { narrowed.hasSpecialFeature = true }
            if features.contains(.themeSongs) { narrowed.hasThemeSong = true }
            if features.contains(.themeVideos) { narrowed.hasThemeVideo = true }
        }
        if videoTypes.contains(.sd) { narrowed.isHD = false }
        if videoTypes.contains(.hd) { narrowed.isHD = true }
        if videoTypes.contains(.uhd) { narrowed.is4K = true }
        if videoTypes.contains(.threeD) { narrowed.is3D = true }
        let discs = LibraryVideoTypeFilter.allCases.filter(videoTypes.contains).compactMap(\.jellyfinVideoType)
        if !discs.isEmpty { narrowed.videoTypes = discs }

        if !genres.isEmpty {
            if let ids = facets?.genreIDs, !ids.isEmpty {
                let resolved = Self.sorted(genres).compactMap { ids[$0.lowercased()] }
                guard !resolved.isEmpty else { return nil }
                narrowed.genreIDs = resolved
            } else {
                guard query.genres == nil else { return nil }
                narrowed.genres = Self.sorted(genres)
            }
        }
        if !studios.isEmpty {
            // A studio tile hides this group, so its own `Studios` never meets the menu's.
            guard query.studioNames == nil else { return nil }
            if let ids = facets?.studioIDs, !ids.isEmpty {
                let resolved = Self.sorted(studios).compactMap { ids[$0.lowercased()] }
                guard !resolved.isEmpty else { return nil }
                narrowed.studioIDs = resolved
            } else {
                narrowed.studioNames = Self.sorted(studios)
            }
        }
        if !officialRatings.isEmpty { narrowed.officialRatings = Self.sorted(officialRatings) }
        if !tags.isEmpty { narrowed.tags = Self.sorted(tags) }
        if !years.isEmpty { narrowed.years = years.sorted() }
        if !audioLanguages.isEmpty { narrowed.audioLanguages = Self.sorted(audioLanguages) }
        if !subtitleLanguages.isEmpty { narrowed.subtitleLanguages = Self.sorted(subtitleLanguages) }
        if !seriesStatus.isEmpty {
            narrowed.seriesStatus = LibrarySeriesStatusFilter.allCases.filter(seriesStatus.contains).map(\.jellyfinValue)
        }
        return narrowed
    }

    /// Stable order, so the same choice always builds the same URL.
    private static func sorted(_ values: Set<String>) -> [String] { values.sorted() }
}

/// Which groups a grid's menu shows. A group the server answered empty stays hidden.
enum LibraryFilterGroups {
    static func visible(for query: ItemQuery, facets: LibraryFacets?) -> [LibraryFilterGroup] {
        LibraryFilterGroup.allCases.filter { group in
            switch group {
            case .filters, .features, .videoType:
                return true
            case .seriesStatus:
                return query.includeItemTypes?.contains(.series) ?? false
            case .genres:
                guard let facets, !facets.genres.isEmpty else { return false }
                // A genre tile can only narrow by more genres through ids (see `applied`).
                return query.genres == nil || facets.byServer.values.contains { !$0.genreIDs.isEmpty }
            case .studios:
                // On a studio or streaming tile the server would take the tile's names and drop ours.
                guard query.studioNames == nil, let facets else { return false }
                return !facets.studios.isEmpty
            case .parentalRatings: return !(facets?.officialRatings.isEmpty ?? true)
            case .tags: return !(facets?.tags.isEmpty ?? true)
            case .years: return !(facets?.years.isEmpty ?? true)
            case .audioLanguages: return !(facets?.audioLanguages.isEmpty ?? true)
            case .subtitleLanguages: return !(facets?.subtitleLanguages.isEmpty ?? true)
            }
        }
    }
}
