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
        static let hiddenTabs = "appearance.hiddenTabs"
        static let showPosterBadges = "appearance.showPosterBadges"
        static let showTopShelfRow = "appearance.showTopShelfRow"
        static let topShelfImage = "appearance.topShelfImage"
        static let showLibraryNames = "appearance.showLibraryNames"
        static let showPosterProgress = "appearance.showPosterProgress"
        static let showCommunityRating = "appearance.showCommunityRating"
        static let showCriticRating = "appearance.showCriticRating"
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

    /// Sodalite#79. Off by default: the pills themselves are free, but filling them in costs a
    /// MediaStreams round trip per row, so only a viewer who wants them pays for them.
    /// tvOS Top Shelf row. On by default; see TopShelfEnabled for why it can be turned off at all.
    var showTopShelfRow: Bool {
        didSet { store.set(showTopShelfRow, forKey: Keys.showTopShelfRow) }
    }

    /// Picture on a Top Shelf cell. Its own setting rather than a reader of the row above, because
    /// a shelf cell is roughly three times the width of a card: a still that holds up in Continue
    /// Watching can be visibly soft up there, and a server's episode stills are capped at its
    /// image-extraction width. Defaults to the episode image, which is what the shelf always drew.
    var topShelfImage: ContinueWatchingImage {
        didSet { store.set(topShelfImage.rawValue, forKey: Keys.topShelfImage) }
    }
    var showPosterBadges: Bool {
        didSet { store.set(showPosterBadges, forKey: Keys.showPosterBadges) }
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

    /// Sodalite#62. Tabs the user switched off; only hideable ones ever land here, so Home and
    /// Settings cannot be stored away even by a synced payload from a future build.
    var hiddenTabs: Set<AppTab> {
        didSet { store.set(hiddenTabs.map(\.rawValue).sorted(), forKey: Keys.hiddenTabs) }
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

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
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
        self.showPosterBadges = store.object(forKey: Keys.showPosterBadges) as? Bool ?? false
        self.showTopShelfRow = store.object(forKey: Keys.showTopShelfRow) as? Bool ?? true
        self.topShelfImage = store.string(forKey: Keys.topShelfImage)
            .flatMap(ContinueWatchingImage.init(rawValue:)) ?? .still
        self.showLibraryNames = store.object(forKey: Keys.showLibraryNames) as? Bool ?? false
        self.showPosterProgress = store.object(forKey: Keys.showPosterProgress) as? Bool ?? false
        self.showCommunityRating = store.object(forKey: Keys.showCommunityRating) as? Bool ?? true
        self.showCriticRating = store.object(forKey: Keys.showCriticRating) as? Bool ?? true
        let storedTabs = store.array(forKey: Keys.hiddenTabs) as? [String] ?? []
        self.hiddenTabs = Set(storedTabs.compactMap(AppTab.init(rawValue:)).filter(\.isHideable))
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
