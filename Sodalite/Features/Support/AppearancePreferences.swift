import Foundation
import Observation
import SwiftUI

/// Supporter-gated cosmetics preserve stored values across refund and repurchase.
@Observable
@MainActor
final class AppearancePreferences {

    typealias AccentChoice = AccentPreset

    // MARK: - Continue Watching image

    enum ContinueWatchingImage: String, CaseIterable, Identifiable, Sendable {
        case still     // the episode's own frame
        case backdrop  // the show's landscape backdrop
        case thumb     // the show's landscape Thumb promo art

        var id: String { rawValue }

        /// Literal keys/defaults so `String(localized:defaultValue:)` compile-time-literal requirement holds.
        var title: String {
            switch self {
            case .still:
                String(localized: "settings.appearance.cwImage.still", defaultValue: "Episode image")
            case .backdrop:
                String(localized: "settings.appearance.cwImage.backdrop", defaultValue: "Backdrop")
            case .thumb:
                String(localized: "settings.appearance.cwImage.thumb", defaultValue: "Thumb")
            }
        }
    }

    // MARK: - Navigation style

    /// Sodalite#140. tvOS only: the shell navigates either from the bar across the top or from the
    /// collapsing sidebar tvOS 26 uses in Apple TV, Music and Podcasts. iOS and iPadOS are on the
    /// sidebar unconditionally and ignore this. It still rides the appearance payload, so a second
    /// Apple TV inherits the choice; iPhone and iPad only carry the value rather than forming an
    /// opinion of their own, which is why the payload field is optional (see CloudSyncPayloads).
    enum NavigationStyle: String, CaseIterable, Identifiable, Sendable {
        case topBar
        case sidebar

        var id: String { rawValue }

        /// Literal keys/defaults so `String(localized:defaultValue:)` compile-time-literal requirement holds.
        var title: String {
            switch self {
            case .topBar:
                String(localized: "settings.tabs.navigation.topBar", defaultValue: "Top bar")
            case .sidebar:
                String(localized: "settings.tabs.navigation.sidebar", defaultValue: "Sidebar")
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let accentChoice = "appearance.accentChoice"
        static let backgroundStyle = "appearance.backgroundStyle"
        static let showContentLogos = "appearance.showContentLogos"
        static let continueWatchingImage = "appearance.continueWatchingImage"
        static let largeCards = "appearance.largeCards"
        static let nowPlayingUsesSeriesPoster = "appearance.nowPlayingUsesSeriesPoster"
        static let spoilerProtectionEnabled = "appearance.spoilerProtection"
        static let spoilerHideEpisodes = "appearance.spoilerHideEpisodes"
        static let spoilerHideMovies = "appearance.spoilerHideMovies"
        static let spoilerHideEpisodeTitles = "appearance.spoilerHideEpisodeTitles"
        static let hiddenTabs = "appearance.hiddenTabs"
        static let hiddenTabsFromNewerBuilds = "appearance.hiddenTabs.newerBuilds"
        static let navigationStyle = "appearance.navigationStyle"
        static let pinnedLibraryTabs = "appearance.pinnedLibraryTabs"
        static let showPosterBadges = "appearance.showPosterBadges"
        static let showDetailBadges = "appearance.showDetailBadges"
        static let showLibraryNames = "appearance.showLibraryNames"
        static let showPosterProgress = "appearance.showPosterProgress"
        static let showCommunityRating = "appearance.showCommunityRating"
        static let showCriticRating = "appearance.showCriticRating"
        static let showTagline = "appearance.showTagline"
    }

    /// 1.3: noticeably bigger Apple TV-style card without dropping so many cards per row that rows feel empty.
    static let largeCardScale: CGFloat = 1.3

    // MARK: - State

    var accentChoice: AccentChoice {
        didSet { store.set(accentChoice.rawValue, forKey: Keys.accentChoice) }
    }

    var backgroundStyle: BackgroundStyle {
        didSet { store.set(backgroundStyle.rawValue, forKey: Keys.backgroundStyle) }
    }

    /// Logo image instead of text title on detail screens; free for everyone, falls back to text when no logo or off. Default on.
    var showContentLogos: Bool {
        didSet { store.set(showContentLogos, forKey: Keys.showContentLogos) }
    }

    var continueWatchingImage: ContinueWatchingImage {
        didSet { store.set(continueWatchingImage.rawValue, forKey: Keys.continueWatchingImage) }
    }

    var largeCards: Bool {
        didSet { store.set(largeCards, forKey: Keys.largeCards) }
    }

    /// Now-Playing artwork uses series poster (Primary), fills square Control Center slot better. Default off. Movies unaffected (no series).
    var nowPlayingUsesSeriesPoster: Bool {
        didSet { store.set(nowPlayingUsesSeriesPoster, forKey: Keys.nowPlayingUsesSeriesPoster) }
    }

    /// Sodalite#50. Opt-in, so the two switches below have no effect while this is off.
    var spoilerProtectionEnabled: Bool {
        didSet { store.set(spoilerProtectionEnabled, forKey: Keys.spoilerProtectionEnabled) }
    }

    var spoilerHideEpisodes: Bool {
        didSet { store.set(spoilerHideEpisodes, forKey: Keys.spoilerHideEpisodes) }
    }

    var spoilerHideMovies: Bool {
        didSet { store.set(spoilerHideMovies, forKey: Keys.spoilerHideMovies) }
    }

    /// Unlike the two above, this one also acts while protection is off: it rides a per-series
    /// "always hide" rule, which is how a single game show gets its names covered.
    var spoilerHideEpisodeTitles: Bool {
        didSet { store.set(spoilerHideEpisodeTitles, forKey: Keys.spoilerHideEpisodeTitles) }
    }

    /// Device value, see DevicePreferences.
    var showTopShelfRow: Bool {
        get { device.showTopShelfRow }
        set { device.showTopShelfRow = newValue }
    }

    /// Device value, see DevicePreferences.
    var topShelfImage: ContinueWatchingImage {
        get { device.topShelfImage }
        set { device.topShelfImage = newValue }
    }

    /// Sodalite#79. Off by default: the pills themselves are free, but filling them in costs a
    /// MediaStreams round trip per row, so only a viewer who wants them pays for them.
    var showPosterBadges: Bool {
        didSet { store.set(showPosterBadges, forKey: Keys.showPosterBadges) }
    }

    /// Sodalite#145. The same facts as the poster pills, plus the audio codec, on the metadata line
    /// of a detail page. On by default, unlike the poster corners: a detail page already holds the
    /// streams it needs, so the pills cost no request, and a page about one title is where a viewer
    /// goes to find out what the copy is.
    var showDetailBadges: Bool {
        didSet { store.set(showDetailBadges, forKey: Keys.showDetailBadges) }
    }

    /// Sodalite#84. Draws the library's name over its artwork on the My Media row. Off by default:
    /// a library image usually has that name burnt into it already, and ours on top reads as two
    /// captions on one tile. On for viewers whose library images carry no text. The fallback tile
    /// is named either way, there being nothing else there to name it.
    var showLibraryNames: Bool {
        didSet { store.set(showLibraryNames, forKey: Keys.showLibraryNames) }
    }

    /// Sodalite#136. Draws the resume capsule on poster and album cards too, not only on the episode
    /// card. Off by default: a poster is a title rather than the thing being watched, and on a row
    /// where most series are partly watched a capsule under every one of them is noise with nothing
    /// to resume. A container still draws nothing even when this is on, because its percentage
    /// counts children watched and there is no resume point behind it (Sodalite#135).
    var showPosterProgress: Bool {
        didSet { store.set(showPosterProgress, forKey: Keys.showPosterProgress) }
    }

    /// Sodalite#127. The star score a community voted on (Jellyfin's CommunityRating, TMDB's vote
    /// average in the catalog). On by default; two switches rather than one because the two scores
    /// come from different places and someone may object to only one of them.
    var showCommunityRating: Bool {
        didSet { store.set(showCommunityRating, forKey: Keys.showCommunityRating) }
    }

    /// Sodalite#127. The Rotten Tomatoes tomatometer, wherever it is drawn.
    var showCriticRating: Bool {
        didSet { store.set(showCriticRating, forKey: Keys.showCriticRating) }
    }

    /// Sodalite#146 round 4. The marketing line a detail page sets against its metadata row. On by
    /// default, and off for a viewer who reads it as a poster slogan on a page about a file they
    /// already own. It joins the switches next to it rather than being argued about: the page
    /// already lets its badges and both scores go.
    var showTagline: Bool {
        didSet { store.set(showTagline, forKey: Keys.showTagline) }
    }

    /// Sodalite#62. Tabs the user switched off; only hideable ones ever land here, so Home and
    /// Settings cannot be stored away even by a synced payload from a future build.
    var hiddenTabs: Set<AppTab> {
        didSet { store.set(hiddenTabs.map(\.rawValue).sorted(), forKey: Keys.hiddenTabs) }
    }

    /// Sodalite#140. Read only by the tvOS shell; switching it rebuilds the TabView, so the
    /// settings screen commits it on the way out rather than under the focused row.
    var navigationStyle: NavigationStyle {
        didSet { store.set(navigationStyle.rawValue, forKey: Keys.navigationStyle) }
    }

    /// Libraries pinned as tabs of their own, in bar order. Read only by the tvOS shell, and
    /// committed by the settings screen on the way out for the same reason as `navigationStyle`.
    var pinnedLibraryTabs: [PinnedLibraryTab] {
        didSet { store.set(try? JSONEncoder().encode(pinnedLibraryTabs), forKey: Keys.pinnedLibraryTabs) }
    }

    /// One assignment, and none for an unchanged list, so a commit rebuilds the bar at most once.
    func setPinnedLibraryTabs(_ tabs: [PinnedLibraryTab]) {
        guard tabs != pinnedLibraryTabs else { return }
        pinnedLibraryTabs = tabs
    }

    var cardScale: CGFloat {
        largeCards ? Self.largeCardScale : 1.0
    }

    func isTabHidden(_ tab: AppTab) -> Bool {
        hiddenTabs.contains(tab)
    }

    func setTab(_ tab: AppTab, hidden: Bool) {
        guard tab.isHideable else { return }
        var next = hiddenTabs
        if hidden {
            next.insert(tab)
        } else {
            next.remove(tab)
        }
        setHiddenTabs(next)
    }

    /// Hidden tabs a synced record named that this build does not have. Kept and written back with
    /// the known ones, or this device's next upload would unhide them on every newer device. Computed
    /// over the keyspace rather than stored, because it is not a setting this build can change.
    var hiddenTabsFromNewerBuilds: [String] {
        get { (store.array(forKey: Keys.hiddenTabsFromNewerBuilds) as? [String]) ?? [] }
        set { store.set(newValue.isEmpty ? nil : newValue.sorted(), forKey: Keys.hiddenTabsFromNewerBuilds) }
    }

    /// The synced form: every hidden tab this build knows, plus the ones only a newer build knows.
    var syncedHiddenTabs: [String] {
        Set(hiddenTabs.map(\.rawValue) + hiddenTabsFromNewerBuilds).sorted()
    }

    /// The inverse of `syncedHiddenTabs`. A name this build knows but cannot hide is dropped.
    func applySyncedHiddenTabs(_ names: [String]) {
        setHiddenTabs(Set(names.compactMap(AppTab.init(rawValue:))))
        hiddenTabsFromNewerBuilds = names.filter { AppTab(rawValue: $0) == nil }
    }

    /// One assignment for a whole set, so the settings screen's deferred commit rebuilds the tab
    /// bar once instead of once per row.
    func setHiddenTabs(_ tabs: Set<AppTab>) {
        let filtered = tabs.filter(\.isHideable)
        guard filtered != hiddenTabs else { return }
        hiddenTabs = filtered
    }

    var storedAccentRawValue: String {
        let fallback = accentChoice.rawValue
        return store.string(forKey: Keys.accentChoice) ?? fallback
    }

    var storedBackgroundRawValue: String {
        let fallback = backgroundStyle.rawValue
        return store.string(forKey: Keys.backgroundStyle) ?? fallback
    }

    // MARK: - Init

    private let store: PreferenceKeyspace
    let device: DevicePreferences

    init(keyspace store: PreferenceKeyspace, device: DevicePreferences) {
        self.store = store
        self.device = device
        let rawAccent = store.string(forKey: Keys.accentChoice) ?? AccentPreset.systemBlue.rawValue
        self.accentChoice = AccentPreset(rawValue: rawAccent) ?? .systemBlue
        let rawBackground = store.string(forKey: Keys.backgroundStyle)
        self.backgroundStyle = rawBackground.flatMap(BackgroundStyle.init(rawValue:))
            ?? .graphiteGlass
        self.showContentLogos = store.object(forKey: Keys.showContentLogos) as? Bool ?? true
        self.continueWatchingImage = store.string(forKey: Keys.continueWatchingImage)
            .flatMap(ContinueWatchingImage.init(rawValue:)) ?? .still
        self.largeCards = store.object(forKey: Keys.largeCards) as? Bool ?? false
        self.nowPlayingUsesSeriesPoster = store.object(forKey: Keys.nowPlayingUsesSeriesPoster) as? Bool ?? false
        self.spoilerProtectionEnabled = store.object(forKey: Keys.spoilerProtectionEnabled) as? Bool ?? false
        self.spoilerHideEpisodes = store.object(forKey: Keys.spoilerHideEpisodes) as? Bool ?? true
        self.spoilerHideMovies = store.object(forKey: Keys.spoilerHideMovies) as? Bool ?? false
        self.spoilerHideEpisodeTitles = store.object(forKey: Keys.spoilerHideEpisodeTitles) as? Bool ?? false
        self.showPosterBadges = store.object(forKey: Keys.showPosterBadges) as? Bool ?? false
        self.showDetailBadges = store.object(forKey: Keys.showDetailBadges) as? Bool ?? true
        self.showLibraryNames = store.object(forKey: Keys.showLibraryNames) as? Bool ?? false
        self.showPosterProgress = store.object(forKey: Keys.showPosterProgress) as? Bool ?? false
        self.showCommunityRating = store.object(forKey: Keys.showCommunityRating) as? Bool ?? true
        self.showCriticRating = store.object(forKey: Keys.showCriticRating) as? Bool ?? true
        self.showTagline = store.object(forKey: Keys.showTagline) as? Bool ?? true
        self.navigationStyle = store.string(forKey: Keys.navigationStyle)
            .flatMap(NavigationStyle.init(rawValue:)) ?? .topBar
        self.pinnedLibraryTabs = (store.object(forKey: Keys.pinnedLibraryTabs) as? Data)
            .flatMap { try? JSONDecoder().decode([PinnedLibraryTab].self, from: $0) } ?? []
        let storedTabs = store.array(forKey: Keys.hiddenTabs) as? [String] ?? []
        // A tab a newer build hid that this build has since learned: it joins the known ones, or it
        // would show here while still being published as hidden. Written straight to the defaults,
        // past `onWrite`: the synced form is the same before and after, so this is no edit.
        let fromNewer = store.array(forKey: Keys.hiddenTabsFromNewerBuilds) as? [String] ?? []
        self.hiddenTabs = Set((storedTabs + fromNewer).compactMap(AppTab.init(rawValue:)).filter(\.isHideable))
        if fromNewer.contains(where: { AppTab(rawValue: $0) != nil }) {
            let unknown = fromNewer.filter { AppTab(rawValue: $0) == nil }.sorted()
            store.defaults.set(unknown.isEmpty ? nil : unknown, forKey: store.fullKey(Keys.hiddenTabsFromNewerBuilds))
            store.defaults.set(hiddenTabs.map(\.rawValue).sorted(), forKey: store.fullKey(Keys.hiddenTabs))
        }
    }

    /// `scope` nil is the unprefixed legacy space. Without a `device`, one is built over the same
    /// defaults, which is what a test or the factory-defaults scratch set wants.
    convenience init(store defaults: UserDefaults = .standard, scope: String? = nil, device: DevicePreferences? = nil) {
        self.init(
            keyspace: PreferenceKeyspace(defaults: defaults, scope: scope),
            device: device ?? DevicePreferences(store: defaults)
        )
    }

    func resolvedTheme(isSupporter: Bool) -> ResolvedAppearanceTheme {
        AppearanceThemeResolver.resolve(
            storedAccent: accentChoice,
            storedBackground: backgroundStyle,
            isSupporter: isSupporter
        )
    }

    func effectiveAccent(isSupporter: Bool) -> AccentChoice {
        resolvedTheme(isSupporter: isSupporter).accent
    }

    /// Never nil: it is the resolved theme's own control colour, and the resolver always lands on a
    /// theme. It used to be Optional, and every consumer's `?? .accentColor` branch stood for a case
    /// that cannot happen while naming the one colour that must not be drawn.
    func effectiveTint(isSupporter: Bool) -> Color {
        resolvedTheme(isSupporter: isSupporter).palette.control.color
    }
}
