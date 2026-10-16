import Foundation

/// Sodalite#50. Decides whether an item's synopsis and still are veiled. A pure value so the
/// whole matrix is unit-testable; the environment reads live in `spoilerVeil`.
/// Nonisolated because the player's title lines are, and they need the title decision.
nonisolated struct SpoilerPolicy: Sendable, Equatable {
    var enabled: Bool
    var hideEpisodes: Bool
    var hideMovies: Bool
    var userID: String
    /// Shared with `SpoilerRevealMemory` by COW, so building a policy per card body is a retain, not a copy.
    var revealedKeys: Set<String>
    /// Sodalite#50 follow-up. Per-series rules, "<userID>|<seriesID>" to "veil this show".
    /// Shared with `SpoilerSeriesRules` by COW like `revealedKeys`. Defaulted so the memberwise
    /// init keeps working for callers that predate it.
    var seriesOverrides: [String: Bool] = [:]
    /// Robius (Discord, 2026-10-08). Off by default: for most shows the name tells nothing, and
    /// for a game show it names who wins. Rides whatever decides the episode is veiled, so a
    /// per-series rule can switch it on for one show while the global switch stays off.
    var hideEpisodeTitles: Bool = false

    /// What is being covered. Not every veiled item veils both.
    enum Surface: Sendable {
        /// Descriptions and synopses.
        case text
        /// Stills, posters, backdrops.
        case artwork
        /// An episode's own name. The series name and the S/E numbers are never covered.
        case title
    }

    static let disabled = SpoilerPolicy(
        enabled: false,
        hideEpisodes: false,
        hideMovies: false,
        userID: "",
        revealedKeys: [],
        seriesOverrides: [:],
        hideEpisodeTitles: false
    )

    /// Per item, deliberately unlike `TrackSelectionMemory.scopeKey`, which folds episodes under
    /// their series: revealing one episode must not reveal the whole season.
    static func key(userID: String, itemID: String) -> String {
        "\(userID)|\(itemID)"
    }

    func key(for item: JellyfinItem) -> String {
        Self.key(userID: userID, itemID: item.id)
    }

    static func seriesKey(userID: String, seriesID: String) -> String {
        "\(userID)|\(seriesID)"
    }

    /// The scope a rule is stored under. Episodes and seasons resolve through their series, a
    /// series through itself; a caller that fetched an episode without SeriesId gets no scope and
    /// falls back to the global default rather than a wrong rule.
    func seriesScopeKey(for item: JellyfinItem) -> String? {
        switch item.type {
        case .series:
            return Self.seriesKey(userID: userID, seriesID: item.id)
        case .episode, .season:
            guard let seriesID = item.seriesId else { return nil }
            return Self.seriesKey(userID: userID, seriesID: seriesID)
        default:
            return nil
        }
    }

    func seriesOverride(for item: JellyfinItem) -> Bool? {
        guard let scope = seriesScopeKey(for: item) else { return nil }
        return seriesOverrides[scope]
    }

    /// What the global switches would do to a show that carries no rule. Drives the button label.
    var seriesDefaultIsHidden: Bool { enabled && hideEpisodes }

    func effectiveHidesSeries(_ seriesID: String) -> Bool {
        seriesOverrides[Self.seriesKey(userID: userID, seriesID: seriesID)] ?? seriesDefaultIsHidden
    }

    /// Artwork is only a spoiler on an episode, where the still is a frame out of that very
    /// episode. A movie poster is marketing art the viewer has already seen everywhere, so
    /// blurring it hides which movie this is rather than what happens in it. A season poster is
    /// the same marketing art, so a season veils its synopsis only.
    func isHidden(_ item: JellyfinItem, surface: Surface) -> Bool {
        guard isHidden(item) else { return false }
        switch surface {
        case .text: return true
        case .artwork: return item.type == .episode
        case .title: return item.type == .episode && hideEpisodeTitles
        }
    }

    /// The episode's name, or nil while `.title` veils it. Feed this to `EpisodeMetadataFormatter`
    /// in place of `item.name`, so the line keeps its series name and numbers and only loses the name.
    func visibleTitle(of item: JellyfinItem) -> String? {
        isHidden(item, surface: .title) ? nil : item.name
    }

    /// For a line that shows the name on its own: a veiled name becomes "Episode 12", never a blank line.
    func displayName(of item: JellyfinItem) -> String {
        if let title = visibleTitle(of: item) { return title }
        if let number = item.indexNumber { return String(localized: "spoiler.episodeNumber \(number)") }
        return String(localized: "spoiler.episode")
    }

    /// The base decision, before any surface narrows it further. A per-series rule replaces the
    /// global default; it deliberately does NOT replace the reveal rules below, or a watched
    /// episode would stay blurred forever and Continue Watching would be a wall of blur again.
    func isHidden(_ item: JellyfinItem) -> Bool {
        switch seriesOverride(for: item) {
        case .some(false):
            return false
        case .some(true):
            // The series page keeps its own synopsis: a premise is not a spoiler, and the user
            // opened that page deliberately.
            guard item.type == .episode || item.type == .season else { return false }
        case .none:
            guard enabled else { return false }
            switch item.type {
            // A season synopsis describes that season's arc, so it is the same class of spoiler as
            // an episode synopsis and rides the same switch.
            case .episode where hideEpisodes: break
            case .season where hideEpisodes: break
            case .movie where hideMovies: break
            default: return false
            }
        }
        if item.userData?.played == true { return false }
        // Started counts as revealed: every Continue Watching entry is in progress, so without
        // this the one row users look at most would be a wall of blur.
        if (item.userData?.playedPercentage ?? 0) > 0 { return false }
        if hasWatchedChild(item) { return false }
        return !revealedKeys.contains(key(for: item))
    }

    /// Same "started reveals" intent one level up: a season carries no played percentage (Jellyfin
    /// computes that for playable items), so a started season is one with at least one episode
    /// watched. Needs both counts, and a caller that skipped ChildCount gets no reveal rather than
    /// a wrong one.
    private func hasWatchedChild(_ item: JellyfinItem) -> Bool {
        guard let total = item.childCount, let unplayed = item.userData?.unplayedItemCount else {
            return false
        }
        return unplayed < total
    }
}

extension SpoilerPolicy {
    /// What the Top Shelf extension needs of this policy, this profile's rules and reveals only.
    /// Off unless the title switch is on, so the mirror stays empty for everyone else.
    var topShelfTitleVeil: TopShelfTitleVeil {
        guard hideEpisodeTitles else { return .off }
        let userPrefix = "\(userID)|"
        let rules = Dictionary(uniqueKeysWithValues: seriesOverrides.compactMap { key, veils in
            key.hasPrefix(userPrefix) ? (String(key.dropFirst(userPrefix.count)), veils) : nil
        })
        let revealed = Set(revealedKeys.compactMap { key in
            key.hasPrefix(userPrefix) ? String(key.dropFirst(userPrefix.count)) : nil
        })
        return TopShelfTitleVeil(hidesByDefault: seriesDefaultIsHidden,
                                 seriesRules: rules,
                                 revealedItemIDs: revealed)
    }
}
