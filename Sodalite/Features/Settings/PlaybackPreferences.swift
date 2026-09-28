import Foundation
import CoreGraphics
import Observation
import AetherEngine

/// Playback settings of one profile (or the legacy unprefixed space), plus pass-throughs to the shared DevicePreferences; read/write via `DependencyContainer.playbackPreferences`.
@Observable
@MainActor
final class PlaybackPreferences {

    // MARK: - Keys

    private enum Keys {
        static let autoplayNextEpisode = "playback.autoplayNextEpisode"
        static let autoplayCountdown = "playback.autoplayCountdown"
        static let nextEpisodeCountdownSeconds = "playback.nextEpisodeCountdownSeconds"
        static let nextEpisodeCountdownAnchor = "playback.nextEpisodeCountdownAnchor"
        static let skipForwardSeconds = "playback.skipForwardSeconds"
        static let skipBackwardSeconds = "playback.skipBackwardSeconds"
        /// The single pre-split interval (Sodalite#144). Seeds both directions on first read
        /// and is then left alone, so a downgrade lands on the value it last knew.
        static let legacySkipIntervalSeconds = "playback.skipIntervalSeconds"
        static let preferredAudioLanguage = "playback.preferredAudioLanguage"
        static let preferredSubtitleLanguage = "playback.preferredSubtitleLanguage"
        static let autoSkipIntro = "playback.autoSkipIntro"
        static let autoSkipRecap = "playback.autoSkipRecap"
        static let autoSkipOutro = "playback.autoSkipOutro"
        static let autoSubtitleForForeignAudio = "playback.autoSubtitleForForeignAudio"
        static let autoForcedSubtitles = "playback.autoForcedSubtitles"
        static let styledASSSubtitles = "playback.styledASSSubtitles"
        static let subtitleFontSize = "playback.subtitleFontSize"
        static let subtitleColor = "playback.subtitleColor"
        static let subtitleBackground = "playback.subtitleBackground"
        /// v2 versioned key; read first, else migrate legacy v1 (legacy "none" -> .shadow).
        static let subtitleBackgroundV2 = "playback.subtitleBackgroundV2"
        static let subtitleDelaySeconds = "playback.subtitleDelaySeconds"
        /// Legacy ±200 pt slider, superseded by SubtitleVerticalPosition; not migrated.
        static let subtitleVerticalOffsetPoints = "playback.subtitleVerticalOffsetPoints"
        static let subtitleVerticalPosition = "playback.subtitleVerticalPosition"
        static let subtitleFont = "playback.subtitleFont"
        static let subtitleWeight = "playback.subtitleWeight"
        static let pictureMode = "playback.pictureMode"
        static let showScrubPreview = "playback.showScrubPreview"
        static let preferServerTrickplay = "playback.preferServerTrickplay"
        static let rememberTrackSelections = "playback.rememberTrackSelections"
        static let subtitlesOnSkipBack = "playback.subtitlesOnSkipBack"
        static let touchpadScrubbing = "playback.touchpadScrubbing"
    }

    // MARK: - Allowed Values

    /// Offered for both directions. Every entry needs an SF Symbol to draw it with, see `SkipGlyph`.
    static let skipIntervalChoices: [Int] = [5, 10, 15, 30]

    /// Countdown lengths offered in Settings. 0 is the countdown switched OFF, never a zero-second
    /// one: on the credits anchor that would be an instant jump, and `autoSkipOutro` already is one.
    static let nextEpisodeCountdownChoices: [Int] = [0, 5, 10, 15, 20, 30]

    /// Negative shifts subs earlier, positive later; finer steps near zero.
    static let subtitleDelayChoices: [Double] = [
        -5, -3, -2, -1.5, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 1.5, 2, 3, 5
    ]

    // Legacy ±200 pt slider replaced by SubtitleVerticalPosition; no migration: ambiguous pt-to-fraction math on the asymmetric new scale.

    /// Alphabetical; ISO 639-2/B bibliographic codes, Jellyfin convention "deu" not "ger".
    private static let baseLanguages: [LanguageChoice] = [
        LanguageChoice(code: "ara", short: "AR",  titleKey: "settings.playback.language.ara"),
        LanguageChoice(code: "chi", short: "ZH",  titleKey: "settings.playback.language.zho"),
        LanguageChoice(code: "cze", short: "CS",  titleKey: "settings.playback.language.ces"),
        LanguageChoice(code: "dan", short: "DA",  titleKey: "settings.playback.language.dan"),
        LanguageChoice(code: "dut", short: "NL",  titleKey: "settings.playback.language.nld"),
        LanguageChoice(code: "eng", short: "EN",  titleKey: "settings.playback.language.eng"),
        LanguageChoice(code: "fin", short: "FI",  titleKey: "settings.playback.language.fin"),
        LanguageChoice(code: "fre", short: "FR",  titleKey: "settings.playback.language.fra"),
        LanguageChoice(code: "ger", short: "DE",  titleKey: "settings.playback.language.deu"),
        LanguageChoice(code: "gre", short: "EL",  titleKey: "settings.playback.language.ell"),
        LanguageChoice(code: "heb", short: "HE",  titleKey: "settings.playback.language.heb"),
        LanguageChoice(code: "hin", short: "HI",  titleKey: "settings.playback.language.hin"),
        LanguageChoice(code: "hun", short: "HU",  titleKey: "settings.playback.language.hun"),
        LanguageChoice(code: "ind", short: "ID",  titleKey: "settings.playback.language.ind"),
        LanguageChoice(code: "ita", short: "IT",  titleKey: "settings.playback.language.ita"),
        LanguageChoice(code: "jpn", short: "JA",  titleKey: "settings.playback.language.jpn"),
        LanguageChoice(code: "kor", short: "KO",  titleKey: "settings.playback.language.kor"),
        LanguageChoice(code: "nor", short: "NO",  titleKey: "settings.playback.language.nor"),
        LanguageChoice(code: "pol", short: "PL",  titleKey: "settings.playback.language.pol"),
        LanguageChoice(code: "por", short: "PT",  titleKey: "settings.playback.language.por"),
        LanguageChoice(code: "rum", short: "RO",  titleKey: "settings.playback.language.ron"),
        LanguageChoice(code: "rus", short: "RU",  titleKey: "settings.playback.language.rus"),
        LanguageChoice(code: "spa", short: "ES",  titleKey: "settings.playback.language.spa"),
        LanguageChoice(code: "swe", short: "SV",  titleKey: "settings.playback.language.swe"),
        LanguageChoice(code: "tha", short: "TH",  titleKey: "settings.playback.language.tha"),
        LanguageChoice(code: "tur", short: "TR",  titleKey: "settings.playback.language.tur"),
        LanguageChoice(code: "ukr", short: "UK",  titleKey: "settings.playback.language.ukr"),
        LanguageChoice(code: "vie", short: "VI",  titleKey: "settings.playback.language.vie"),
    ]

    static var audioLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    /// "Auto" first; nil code lets per-track auto-pick decide, an explicit code pins it.
    static var subtitleLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    struct LanguageChoice: Hashable, Sendable {
        /// ISO 639-2/B code (Jellyfin convention "deu"), or nil for stream default.
        let code: String?
        let short: String
        let titleKey: String
    }

    /// Sizes calibrated for tvOS viewing distance, ~32 pt (small) to ~68 pt (xlarge).
    enum SubtitleFontSize: String, CaseIterable, Sendable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.size.\(rawValue)" }
        /// Multiplier on the 28 pt base, geometric growth so each step reads distinctly bigger.
        var scale: CGFloat {
            switch self {
            case .small: return 1.15
            case .medium: return 1.45
            case .large: return 1.85
            case .xlarge: return 2.4
            }
        }
    }

    enum SubtitleColor: String, CaseIterable, Sendable, Identifiable {
        case white, yellow, gray
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.color.\(rawValue)" }
    }

    /// .shadow preserves old .none misnomer behavior (shadow was always there) so no visual change after case split; .none is now truly naked text.
    enum SubtitleBackground: String, CaseIterable, Sendable, Identifiable {
        case box, outline, shadow, none
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.background.\(rawValue)" }
    }

    /// Downward-only fraction-of-player-rect steps, no negative half; explicit `default` opt-out matters for PGS/DVB/DVD source-baked positions.
    enum SubtitleVerticalPosition: String, CaseIterable, Sendable, Identifiable {
        case `default`
        case bottom
        case step1
        case step2
        case step3

        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.position.\(rawValue)" }

        /// Fraction of player rect height from bottom edge; nil = no override (historical baseline, bitmap cues untouched).
        var fractionFromBottom: Double? {
            switch self {
            case .default: return nil
            // 0 = flush with the screen bottom, distinct from nil: the letterbox bar varies with
            // aspect ratio, so any positive anchor centres in it only at one ratio (#15).
            case .bottom:  return 0
            case .step1:   return 0.10
            case .step2:   return 0.20
            case .step3:   return 0.30
            }
        }
    }

    /// highLegibility = bundled Atkinson Hyperlegible; text cues only, bitmap cues ignore it.
    enum SubtitleFont: String, CaseIterable, Sendable, Identifiable {
        case system, highLegibility
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.font.\(rawValue)" }
    }

    /// Text cues only; bitmap cues are pre-rendered and ignore weight.
    enum SubtitleWeight: String, CaseIterable, Sendable, Identifiable {
        case regular, bold
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.weight.\(rawValue)" }
    }

    /// Live TV teletext caption page (#107). `auto` = libzvbi auto-detect; explicit pages target
    /// channels libzvbi does not flag (888 = EU/UK subtitle page, 801 = AU, 777 = common alt).
    /// Maps to the engine's `LoadOptions.teletextPage`.
    enum LiveTeletextPage: String, CaseIterable, Sendable, Identifiable {
        case auto, p888, p801, p777
        var id: String { rawValue }
        var titleKey: String { "settings.playback.teletext.\(rawValue)" }
        var page: Int? {
            switch self {
            case .auto: return nil
            case .p888: return 888
            case .p801: return 801
            case .p777: return 777
            }
        }
    }

    /// `original` keeps aspect ratio (letterbox), `fill` crops to cover; maps to AVLayerVideoGravity in the engine.
    enum PictureMode: String, CaseIterable, Sendable, Identifiable {
        case original, fill
        var id: String { rawValue }
        var titleKey: String { "settings.playback.picture.\(rawValue)" }
    }

    /// VOD forward read-ahead window (Issue #33), passed to the engine as LoadOptions.forwardBufferSegments
    /// (engine clamp 4...2700 at 4 s/segment). nil = engine default (10 seg / ~40 s). Deeper buffers help slow
    /// network mounts but trade away rewind depth on fast servers (shared disk budget).
    /// `unlimited` sends the engine's whole-source sentinel (AE#207): past 150 segments the engine bounds the
    /// prefetch in bytes, not segments, running until it fills a quarter of the volume's free space and then
    /// tracking the playhead, so it buffers as much of the title as safely fits.
    enum NetworkBufferDepth: String, CaseIterable, Sendable, Identifiable {
        case system, oneMinute, fiveMinutes, maximum, unlimited
        var id: String { rawValue }
        var titleKey: String { "settings.playback.buffer.\(rawValue)" }
        var forwardBufferSegments: Int? {
            switch self {
            case .system:      return nil
            case .oneMinute:   return 15   // ~60 s
            case .fiveMinutes: return 75   // ~300 s
            case .maximum:     return 150  // ~600 s
            case .unlimited:   return Int.max   // AE#207 whole-source sentinel, engine clamps to 2700
            }
        }
    }

    /// Sodalite#104: how much of a live channel the session records behind the live edge, which is
    /// how far back the transport can be scrubbed.
    ///
    /// This used to be ten minutes, hard-coded in both live load paths, and ten minutes is under a
    /// third of an ordinary programme: the rail could frame a football match and let a viewer reach
    /// almost none of it. The depth is bounded by the engine whatever is asked for here
    /// (`sessionRetentionBudgetBytes` caps the session at 2 GiB or a quarter of free space, and the
    /// resident floor stops the seekable range advertising history the cache no longer holds), so a
    /// deep default costs a viewer nothing on a small disk.
    enum LiveBufferDepth: String, CaseIterable, Sendable, Identifiable {
        case tenMinutes, thirtyMinutes, ninetyMinutes, threeHours
        var id: String { rawValue }
        var titleKey: String { "settings.playback.liveBuffer.\(rawValue)" }
        var seconds: Double {
            switch self {
            case .tenMinutes:    return 10 * 60
            case .thirtyMinutes: return 30 * 60
            case .ninetyMinutes: return 90 * 60
            case .threeHours:    return 3 * 3600
            }
        }
    }

    // MARK: - Properties

    var autoplayNextEpisode: Bool {
        didSet { store.set(autoplayNextEpisode, forKey: Keys.autoplayNextEpisode) }
    }

    /// Off keeps the next-episode card but drops its timer, so the episode plays to its end (credits,
    /// post-credit scenes) before the switch (Sodalite#67). Inert while `autoplayNextEpisode` is off.
    var autoplayCountdown: Bool {
        didSet { store.set(autoplayCountdown, forKey: Keys.autoplayCountdown) }
    }

    var autoSkipIntro: Bool {
        didSet { store.set(autoSkipIntro, forKey: Keys.autoSkipIntro) }
    }

    var autoSkipRecap: Bool {
        didSet { store.set(autoSkipRecap, forKey: Keys.autoSkipRecap) }
    }

    var autoSkipOutro: Bool {
        didSet { store.set(autoSkipOutro, forKey: Keys.autoSkipOutro) }
    }

    /// How long the countdown runs once armed. Inert while `autoplayCountdown` is off; read through
    /// `nextEpisodeCountdownLength`, which folds the two together.
    var nextEpisodeCountdownSeconds: Int {
        didSet { store.set(nextEpisodeCountdownSeconds, forKey: Keys.nextEpisodeCountdownSeconds) }
    }

    /// Where the countdown sits (Sodalite#133). Defaults to the credits, which is what shipped, so an
    /// untouched install keeps its behaviour.
    var nextEpisodeCountdownAnchor: NextEpisodePolicy.CountdownAnchor {
        didSet { store.set(nextEpisodeCountdownAnchor.rawValue, forKey: Keys.nextEpisodeCountdownAnchor) }
    }

    /// The single value the settings row and the player both use: 0 while the countdown is off, the
    /// chosen length otherwise. Kept computed on purpose. `autoplayCountdown` stays the truth for off
    /// (older builds sync that flag, and `endOfPlaybackOutcome` reads it), while the length survives a
    /// trip through off untouched, so switching back on restores the value instead of the default.
    var nextEpisodeCountdownLength: Int {
        get { autoplayCountdown ? nextEpisodeCountdownSeconds : 0 }
        set {
            if newValue <= 0 {
                autoplayCountdown = false
            } else {
                nextEpisodeCountdownSeconds = newValue
                autoplayCountdown = true
            }
        }
    }

    /// Sodalite#144: the two directions are set apart, because reaching back for a line of dialogue
    /// and jumping past a stretch are different distances. Both default to the pre-split interval, so
    /// an install that never touches this keeps exactly the jumps it had.
    var skipForwardSeconds: Int {
        didSet { store.set(skipForwardSeconds, forKey: Keys.skipForwardSeconds) }
    }

    var skipBackwardSeconds: Int {
        didSet { store.set(skipBackwardSeconds, forKey: Keys.skipBackwardSeconds) }
    }

    /// The interval a jump in `direction` covers; negative is back, anything else forward. The one
    /// place the direction-to-value question is answered, so a new transport cannot get it wrong.
    func skipSeconds(direction: Int) -> Int {
        direction < 0 ? skipBackwardSeconds : skipForwardSeconds
    }

    var preferredAudioLanguage: String? {
        didSet { store.set(preferredAudioLanguage, forKey: Keys.preferredAudioLanguage) }
    }

    var preferredSubtitleLanguage: String? {
        didSet { store.set(preferredSubtitleLanguage, forKey: Keys.preferredSubtitleLanguage) }
    }

    /// Auto-enable subs when audio isn't in preferred language; default ON per streaming-app convention.
    var autoSubtitleForForeignAudio: Bool {
        didSet { store.set(autoSubtitleForForeignAudio, forKey: Keys.autoSubtitleForForeignAudio) }
    }

    /// Disc parity: render forced captions (signs, foreign dialogue) even with subtitles off. Default ON,
    /// matching how the feature shipped before it had a switch. See `ForcedSubtitleFallback`.
    var autoForcedSubtitles: Bool {
        didSet { store.set(autoForcedSubtitles, forKey: Keys.autoForcedSubtitles) }
    }

    /// Render ASS/SSA with authored styling via libass; OFF falls back to plain text path (user style settings apply).
    var styledASSSubtitles: Bool {
        didSet { store.set(styledASSSubtitles, forKey: Keys.styledASSSubtitles) }
    }

    var subtitleFontSize: SubtitleFontSize {
        didSet { store.set(subtitleFontSize.rawValue, forKey: Keys.subtitleFontSize) }
    }

    var subtitleColor: SubtitleColor {
        didSet { store.set(subtitleColor.rawValue, forKey: Keys.subtitleColor) }
    }

    var subtitleBackground: SubtitleBackground {
        // Write the versioned key; legacy key left intact for downgrade.
        didSet { store.set(subtitleBackground.rawValue, forKey: Keys.subtitleBackgroundV2) }
    }

    /// Applied in SubtitleOverlayView as effectiveTime = currentTime - delay (covers engine + legacy SRTParser paths).
    var subtitleDelaySeconds: Double {
        didSet { store.set(subtitleDelaySeconds, forKey: Keys.subtitleDelaySeconds) }
    }

    var subtitleVerticalPosition: SubtitleVerticalPosition {
        didSet { store.set(subtitleVerticalPosition.rawValue, forKey: Keys.subtitleVerticalPosition) }
    }

    var subtitleFont: SubtitleFont {
        didSet { store.set(subtitleFont.rawValue, forKey: Keys.subtitleFont) }
    }

    var subtitleWeight: SubtitleWeight {
        didSet { store.set(subtitleWeight.rawValue, forKey: Keys.subtitleWeight) }
    }

    /// Default for new sessions; in-player picture button overrides transiently on PlayerViewModel, not here.
    var pictureMode: PictureMode {
        didSet { store.set(pictureMode.rawValue, forKey: Keys.pictureMode) }
    }

    var showScrubPreview: Bool {
        didSet { store.set(showScrubPreview, forKey: Keys.showScrubPreview) }
    }

    /// ON = scrub preview pulls Jellyfin server trickplay tiles when the item has them (decode-free),
    /// else the on-device FrameExtractor. Default OFF (the FrameExtractor is the default source).
    var preferServerTrickplay: Bool {
        didSet { store.set(preferServerTrickplay, forKey: Keys.preferServerTrickplay) }
    }

    /// Sodalite#46: remember the manual audio/subtitle pick per movie and per series.
    /// Off means the memory is neither read nor written; existing entries stay on disk.
    var rememberTrackSelections: Bool {
        didSet { store.set(rememberTrackSelections, forKey: Keys.rememberTrackSelections) }
    }

    /// Sodalite#114 (tvOS): OFF stops a horizontal swipe over the remote's touch surface from moving
    /// the playhead, for people who drive the box by clicking the ring and keep brushing the pad.
    /// Default ON. Vertical swipes and the list navigation inside menus are untouched, there the swipe
    /// is the navigation.
    var touchpadScrubbing: Bool {
        didSet { store.set(touchpadScrubbing, forKey: Keys.touchpadScrubbing) }
    }

    /// Sodalite#63: after a backward jump, show subtitles until playback reaches the position the jump
    /// started from, like the tvOS system setting. Default ON, which is what the request asked for; a
    /// user who deliberately watches without subtitles turns it off here.
    var subtitlesOnSkipBack: Bool {
        didSet { store.set(subtitlesOnSkipBack, forKey: Keys.subtitlesOnSkipBack) }
    }

    // MARK: - Device values

    // Pass-throughs to the one `DevicePreferences` every profile shares; see there.

    var showStatsForNerds: Bool {
        get { device.showStatsForNerds }
        set { device.showStatsForNerds = newValue }
    }

    var showEngineDiagnostics: Bool {
        get { device.showEngineDiagnostics }
        set { device.showEngineDiagnostics = newValue }
    }

    var preferLosslessAudioBridge: Bool {
        get { device.preferLosslessAudioBridge }
        set { device.preferLosslessAudioBridge = newValue }
    }

    var playerRotationLocked: Bool {
        get { device.playerRotationLocked }
        set { device.playerRotationLocked = newValue }
    }

    var networkBufferDepth: NetworkBufferDepth {
        get { device.networkBufferDepth }
        set { device.networkBufferDepth = newValue }
    }

    var liveBufferDepth: LiveBufferDepth {
        get { device.liveBufferDepth }
        set { device.liveBufferDepth = newValue }
    }

    var streamingQualityWifi: StreamingQuality {
        get { device.streamingQualityWifi }
        set { device.streamingQualityWifi = newValue }
    }

    var streamingQualityCellular: StreamingQuality {
        get { device.streamingQualityCellular }
        set { device.streamingQualityCellular = newValue }
    }

    /// The rung a new session starts on, read once at session start (Sodalite#87).
    func defaultStreamingQuality(
        reading: NetworkPathSnapshot.Reading? = NetworkPathSnapshot.shared.current
    ) -> StreamingQuality {
        #if os(tvOS)
        let platformHasCellular = false
        #else
        let platformHasCellular = true
        #endif
        return StreamingQuality.resolve(wifi: streamingQualityWifi, cellular: streamingQualityCellular,
                                        reading: reading, platformHasCellular: platformHasCellular)
    }

    var liveTeletextPage: LiveTeletextPage {
        get { device.liveTeletextPage }
        set { device.liveTeletextPage = newValue }
    }

    var forceDolbyVisionOnNonDVDisplay: Bool {
        get { device.forceDolbyVisionOnNonDVDisplay }
        set { device.forceDolbyVisionOnNonDVDisplay = newValue }
    }

    var audioBridgeMode: AudioBridgeMode {
        preferLosslessAudioBridge ? .lossless : .surroundCompat
    }

    // MARK: - Init

    private let store: PreferenceKeyspace
    let device: DevicePreferences

    /// Prefer v2 versioned key, else migrate legacy: legacy "none" -> .shadow (it drew a drop shadow); fallback .box.
    private static func loadSubtitleBackground(from store: PreferenceKeyspace) -> SubtitleBackground {
        if let v2 = store.string(forKey: Keys.subtitleBackgroundV2),
           let parsed = SubtitleBackground(rawValue: v2) {
            return parsed
        }
        guard let legacy = store.string(forKey: Keys.subtitleBackground) else {
            return .box
        }
        switch legacy {
        case "none":    return .shadow
        case "box":     return .box
        case "outline": return .outline
        default:        return .box
        }
    }

    init(keyspace store: PreferenceKeyspace, device: DevicePreferences) {
        self.store = store
        self.device = device
        self.autoplayNextEpisode = store.object(forKey: Keys.autoplayNextEpisode) as? Bool ?? true
        self.autoplayCountdown = store.object(forKey: Keys.autoplayCountdown) as? Bool ?? true
        self.autoSkipIntro = store.object(forKey: Keys.autoSkipIntro) as? Bool ?? false
        self.autoSkipRecap = store.object(forKey: Keys.autoSkipRecap) as? Bool ?? false
        self.autoSkipOutro = store.object(forKey: Keys.autoSkipOutro) as? Bool ?? false
        self.nextEpisodeCountdownSeconds = store.object(forKey: Keys.nextEpisodeCountdownSeconds) as? Int ?? 15
        self.nextEpisodeCountdownAnchor = (store.string(forKey: Keys.nextEpisodeCountdownAnchor))
            .flatMap(NextEpisodePolicy.CountdownAnchor.init(rawValue:)) ?? .outro
        let legacySkipInterval = store.object(forKey: Keys.legacySkipIntervalSeconds) as? Int ?? 10
        self.skipForwardSeconds = store.object(forKey: Keys.skipForwardSeconds) as? Int ?? legacySkipInterval
        self.skipBackwardSeconds = store.object(forKey: Keys.skipBackwardSeconds) as? Int ?? legacySkipInterval
        self.preferredAudioLanguage = store.string(forKey: Keys.preferredAudioLanguage)
        self.preferredSubtitleLanguage = store.string(forKey: Keys.preferredSubtitleLanguage)
        self.autoSubtitleForForeignAudio = store.object(forKey: Keys.autoSubtitleForForeignAudio) as? Bool ?? true
        self.autoForcedSubtitles = store.object(forKey: Keys.autoForcedSubtitles) as? Bool ?? true
        self.styledASSSubtitles = store.object(forKey: Keys.styledASSSubtitles) as? Bool ?? true
        self.subtitleFontSize = (store.string(forKey: Keys.subtitleFontSize))
            .flatMap(SubtitleFontSize.init(rawValue:)) ?? .medium
        self.subtitleColor = (store.string(forKey: Keys.subtitleColor))
            .flatMap(SubtitleColor.init(rawValue:)) ?? .white
        self.subtitleBackground = Self.loadSubtitleBackground(from: store)
        self.subtitleDelaySeconds = store.object(forKey: Keys.subtitleDelaySeconds) as? Double ?? 0
        self.subtitleVerticalPosition = (store.string(forKey: Keys.subtitleVerticalPosition))
            .flatMap(SubtitleVerticalPosition.init(rawValue:)) ?? .default
        self.subtitleFont = (store.string(forKey: Keys.subtitleFont))
            .flatMap(SubtitleFont.init(rawValue:)) ?? .system
        self.subtitleWeight = (store.string(forKey: Keys.subtitleWeight))
            .flatMap(SubtitleWeight.init(rawValue:)) ?? .regular
        self.pictureMode = (store.string(forKey: Keys.pictureMode))
            .flatMap(PictureMode.init(rawValue:)) ?? .original
        self.showScrubPreview = store.object(forKey: Keys.showScrubPreview) as? Bool ?? true
        self.preferServerTrickplay = store.object(forKey: Keys.preferServerTrickplay) as? Bool ?? false
        self.rememberTrackSelections = store.object(forKey: Keys.rememberTrackSelections) as? Bool ?? true
        self.subtitlesOnSkipBack = store.object(forKey: Keys.subtitlesOnSkipBack) as? Bool ?? true
        self.touchpadScrubbing = store.object(forKey: Keys.touchpadScrubbing) as? Bool ?? true
    }

    /// `scope` nil is the unprefixed legacy space. Without a `device`, one is built over the same
    /// defaults, which is what a test or the factory-defaults scratch set wants.
    convenience init(store defaults: UserDefaults = .standard, scope: String? = nil, device: DevicePreferences? = nil) {
        self.init(
            keyspace: PreferenceKeyspace(defaults: defaults, scope: scope),
            device: device ?? DevicePreferences(store: defaults)
        )
    }
}
