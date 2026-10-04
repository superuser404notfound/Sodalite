import Foundation

/// Which of a profile's three records a payload belongs to. Three rather than one because playback,
/// appearance and home rows have always resolved last-writer-wins separately, and one record would
/// let an accent change on the iPhone erase a subtitle change made on the Apple TV at the same time.
enum ProfileRecordKind: String, CaseIterable, Codable, Sendable {
    case playback
    case appearance
    case home

    /// The pre-change record that still mirrors this kind for older builds. Home rows are mirrored
    /// by the server record instead, which the home change notifications already republish.
    var legacyStoreKey: CloudSyncStoreKey? {
        switch self {
        case .playback: .playback
        case .appearance: .appearance
        case .home: nil
        }
    }
}

extension CloudSyncStoreKey {
    /// Legacy records whose personal half now comes from a profile and whose device half from
    /// DevicePreferences. They are uploaded from write hooks, not from observation.
    var isProfileBacked: Bool { self == .playback || self == .appearance }
}

/// One profile's playback settings. New fields added later must be Optional, like every late field
/// on the legacy payloads, or an older build drops the whole record.
struct ProfilePlaybackPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var autoplayNextEpisode: Bool
    var autoplayCountdown: Bool
    var autoSkipIntro: Bool
    var autoSkipRecap: Bool
    var autoSkipOutro: Bool
    var nextEpisodeCountdownSeconds: Int
    var nextEpisodeCountdownAnchor: String
    var skipForwardSeconds: Int
    var skipBackwardSeconds: Int
    var preferredAudioLanguage: String?
    var preferredSubtitleLanguage: String?
    var autoSubtitleForForeignAudio: Bool
    var autoForcedSubtitles: Bool
    var styledASSSubtitles: Bool
    var subtitleFontSize: String
    var subtitleColor: String
    var subtitleBackground: String
    var subtitleDelaySeconds: Double
    var subtitleVerticalPosition: String
    var subtitleFont: String
    var subtitleWeight: String
    var pictureMode: String
    var showScrubPreview: Bool
    var preferServerTrickplay: Bool
    var rememberTrackSelections: Bool
    var subtitlesOnSkipBack: Bool
    /// Optional because it arrived hours after this payload shipped (e1ef97bc after aca3e7a7), and a
    /// record written in between has no such key. Non-optional, that record failed to decode on every
    /// later build and the profile's playback settings never reached another device. nil keeps the
    /// local value.
    var touchpadScrubbing: Bool?
}

extension ProfilePlaybackPayload {
    @MainActor
    init(collecting p: PlaybackPreferences, stamp: Date) {
        self.init(
            updatedAt: stamp,
            autoplayNextEpisode: p.autoplayNextEpisode,
            autoplayCountdown: p.autoplayCountdown,
            autoSkipIntro: p.autoSkipIntro,
            autoSkipRecap: p.autoSkipRecap,
            autoSkipOutro: p.autoSkipOutro,
            nextEpisodeCountdownSeconds: p.nextEpisodeCountdownSeconds,
            nextEpisodeCountdownAnchor: p.nextEpisodeCountdownAnchor.rawValue,
            skipForwardSeconds: p.skipForwardSeconds,
            skipBackwardSeconds: p.skipBackwardSeconds,
            preferredAudioLanguage: p.preferredAudioLanguage,
            preferredSubtitleLanguage: p.preferredSubtitleLanguage,
            autoSubtitleForForeignAudio: p.autoSubtitleForForeignAudio,
            autoForcedSubtitles: p.autoForcedSubtitles,
            styledASSSubtitles: p.styledASSSubtitles,
            subtitleFontSize: p.subtitleFontSize.rawValue,
            subtitleColor: p.subtitleColor.rawValue,
            subtitleBackground: p.subtitleBackground.rawValue,
            subtitleDelaySeconds: p.subtitleDelaySeconds,
            subtitleVerticalPosition: p.subtitleVerticalPosition.rawValue,
            subtitleFont: p.subtitleFont.rawValue,
            subtitleWeight: p.subtitleWeight.rawValue,
            pictureMode: p.pictureMode.rawValue,
            showScrubPreview: p.showScrubPreview,
            preferServerTrickplay: p.preferServerTrickplay,
            rememberTrackSelections: p.rememberTrackSelections,
            subtitlesOnSkipBack: p.subtitlesOnSkipBack,
            touchpadScrubbing: p.touchpadScrubbing
        )
    }

    /// Unknown raw values keep the current value, so a newer build's case never resets a setting here.
    @MainActor
    func apply(to p: PlaybackPreferences) {
        p.autoplayNextEpisode = autoplayNextEpisode
        p.autoplayCountdown = autoplayCountdown
        p.autoSkipIntro = autoSkipIntro
        p.autoSkipRecap = autoSkipRecap
        p.autoSkipOutro = autoSkipOutro
        p.nextEpisodeCountdownSeconds = nextEpisodeCountdownSeconds
        p.nextEpisodeCountdownAnchor = NextEpisodePolicy.CountdownAnchor(rawValue: nextEpisodeCountdownAnchor) ?? p.nextEpisodeCountdownAnchor
        p.skipForwardSeconds = skipForwardSeconds
        p.skipBackwardSeconds = skipBackwardSeconds
        p.preferredAudioLanguage = preferredAudioLanguage
        p.preferredSubtitleLanguage = preferredSubtitleLanguage
        p.autoSubtitleForForeignAudio = autoSubtitleForForeignAudio
        p.autoForcedSubtitles = autoForcedSubtitles
        p.styledASSSubtitles = styledASSSubtitles
        p.subtitleFontSize = PlaybackPreferences.SubtitleFontSize(rawValue: subtitleFontSize) ?? p.subtitleFontSize
        p.subtitleColor = PlaybackPreferences.SubtitleColor(rawValue: subtitleColor) ?? p.subtitleColor
        p.subtitleBackground = PlaybackPreferences.SubtitleBackground(rawValue: subtitleBackground) ?? p.subtitleBackground
        p.subtitleDelaySeconds = subtitleDelaySeconds
        p.subtitleVerticalPosition = PlaybackPreferences.SubtitleVerticalPosition(rawValue: subtitleVerticalPosition) ?? p.subtitleVerticalPosition
        p.subtitleFont = PlaybackPreferences.SubtitleFont(rawValue: subtitleFont) ?? p.subtitleFont
        p.subtitleWeight = PlaybackPreferences.SubtitleWeight(rawValue: subtitleWeight) ?? p.subtitleWeight
        p.pictureMode = PlaybackPreferences.PictureMode(rawValue: pictureMode) ?? p.pictureMode
        p.showScrubPreview = showScrubPreview
        p.preferServerTrickplay = preferServerTrickplay
        p.rememberTrackSelections = rememberTrackSelections
        p.subtitlesOnSkipBack = subtitlesOnSkipBack
        if let touchpadScrubbing { p.touchpadScrubbing = touchpadScrubbing }
    }
}

/// One profile's appearance settings. Same Optional rule for later fields.
struct ProfileAppearancePayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var accentChoice: String
    var backgroundStyle: String
    var showContentLogos: Bool
    var continueWatchingImage: String
    var largeCards: Bool
    var nowPlayingUsesSeriesPoster: Bool
    var spoilerProtectionEnabled: Bool
    var spoilerHideEpisodes: Bool
    var spoilerHideMovies: Bool
    var hiddenTabs: [String]
    var navigationStyle: String
    var showPosterBadges: Bool
    var showDetailBadges: Bool
    var showLibraryNames: Bool
    var showPosterProgress: Bool
    var showCommunityRating: Bool
    var showCriticRating: Bool
    /// nil from a build without the tagline switch (Sodalite#146 round 4). Optional and unapplied
    /// when absent, the rule this file states at the top: a sender that has no opinion must not
    /// hand one over.
    var showTagline: Bool?
}

extension ProfileAppearancePayload {
    /// The stored raw accent and background, not the resolved ones, so a supporter-gated choice
    /// survives the trip exactly as the legacy record keeps it.
    @MainActor
    init(collecting a: AppearancePreferences, stamp: Date) {
        self.init(
            updatedAt: stamp,
            accentChoice: a.storedAccentRawValue,
            backgroundStyle: a.storedBackgroundRawValue,
            showContentLogos: a.showContentLogos,
            continueWatchingImage: a.continueWatchingImage.rawValue,
            largeCards: a.largeCards,
            nowPlayingUsesSeriesPoster: a.nowPlayingUsesSeriesPoster,
            spoilerProtectionEnabled: a.spoilerProtectionEnabled,
            spoilerHideEpisodes: a.spoilerHideEpisodes,
            spoilerHideMovies: a.spoilerHideMovies,
            hiddenTabs: a.syncedHiddenTabs,
            navigationStyle: a.navigationStyle.rawValue,
            showPosterBadges: a.showPosterBadges,
            showDetailBadges: a.showDetailBadges,
            showLibraryNames: a.showLibraryNames,
            showPosterProgress: a.showPosterProgress,
            showCommunityRating: a.showCommunityRating,
            showCriticRating: a.showCriticRating,
            showTagline: a.showTagline
        )
    }

    @MainActor
    func apply(to a: AppearancePreferences) {
        if let accent = AppearancePreferences.AccentChoice(rawValue: accentChoice) { a.accentChoice = accent }
        if let background = BackgroundStyle(rawValue: backgroundStyle) { a.backgroundStyle = background }
        a.showContentLogos = showContentLogos
        a.continueWatchingImage = AppearancePreferences.ContinueWatchingImage(rawValue: continueWatchingImage) ?? a.continueWatchingImage
        a.largeCards = largeCards
        a.nowPlayingUsesSeriesPoster = nowPlayingUsesSeriesPoster
        a.spoilerProtectionEnabled = spoilerProtectionEnabled
        a.spoilerHideEpisodes = spoilerHideEpisodes
        a.spoilerHideMovies = spoilerHideMovies
        a.applySyncedHiddenTabs(hiddenTabs)
        a.navigationStyle = AppearancePreferences.NavigationStyle(rawValue: navigationStyle) ?? a.navigationStyle
        a.showPosterBadges = showPosterBadges
        a.showDetailBadges = showDetailBadges
        a.showLibraryNames = showLibraryNames
        a.showPosterProgress = showPosterProgress
        a.showCommunityRating = showCommunityRating
        a.showCriticRating = showCriticRating
        if let showTagline { a.showTagline = showTagline }
    }
}

/// One profile's home rows, collection grouping and library sorts. `configsJSON` stays the opaque
/// stored JSON for the same reason `HomeRowsSyncState` keeps it opaque: the lossy decode in
/// `HomeRowConfig.loadFromStorage` is the forward compatibility.
struct ProfileHomePayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var configsJSON: Data?
    var mergeCWNextUp: Bool
    var rewatchNextUp: Bool
    var collectionGrouping: String
    var librarySorts: [String: String]
    /// Combine servers (Sodalite#85). Optional so a record from an older build decodes.
    var combineServers: Bool?
    var combineServersExcluded: [String]?
    /// My Media order and hiding (Sodalite#85). Optional so a record from an older build decodes.
    var libraryLayoutJSON: Data?
}

/// Type-erased profile payload, the per-profile counterpart of `SettingsSyncPayload`.
enum ProfileSyncPayload: Equatable {
    case playback(ProfilePlaybackPayload)
    case appearance(ProfileAppearancePayload)
    case home(ProfileHomePayload)

    var kind: ProfileRecordKind {
        switch self {
        case .playback: .playback
        case .appearance: .appearance
        case .home: .home
        }
    }

    var updatedAt: Date {
        switch self {
        case .playback(let p): p.updatedAt
        case .appearance(let p): p.updatedAt
        case .home(let p): p.updatedAt
        }
    }

    var knownFields: Set<String> {
        switch self {
        case .playback(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .appearance(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        case .home(let p): CloudSyncForwardCompat.storedPropertyNames(of: p)
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .playback(let p): try JSONEncoder().encode(p)
        case .appearance(let p): try JSONEncoder().encode(p)
        case .home(let p): try JSONEncoder().encode(p)
        }
    }

    static func decode(_ data: Data, kind: ProfileRecordKind) throws -> ProfileSyncPayload {
        switch kind {
        case .playback: .playback(try JSONDecoder().decode(ProfilePlaybackPayload.self, from: data))
        case .appearance: .appearance(try JSONDecoder().decode(ProfileAppearancePayload.self, from: data))
        case .home: .home(try JSONDecoder().decode(ProfileHomePayload.self, from: data))
        }
    }
}
