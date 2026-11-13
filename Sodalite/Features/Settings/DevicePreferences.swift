import Foundation
import Observation
import AetherEngine

/// Values that describe this box, its display, its remote or its network, not the person watching.
/// Shared by every profile on the device and stored under the keys they always had. Written into the
/// legacy `settings-playback` / `settings-appearance` records for builds that still read them there,
/// never applied from those records: another device's box says nothing about this one. `PlaybackPreferences`
/// and `AppearancePreferences` pass them through, so call sites read them where they always did.
@Observable
@MainActor
final class DevicePreferences {

    private enum Keys {
        static let showStatsForNerds = "playback.showStatsForNerds"
        static let showEngineDiagnostics = "playback.showEngineDiagnostics"
        static let preferLosslessAudioBridge = "playback.preferLosslessAudioBridge"
        static let trueHDAtmosHeights = "playback.trueHDAtmosHeights"
        static let objectAudioLayout = "playback.objectAudioLayout"
        static let playerRotationLocked = "playback.playerRotationLocked"
        static let networkBufferDepth = "playback.networkBufferDepth"
        static let liveBufferDepth = "playback.liveBufferDepth"
        static let liveDelay = "playback.liveDelay"
        static let liveTeletextPage = "playback.liveTeletextPage"
        static let streamingQualityWifi = "playback.streamingQualityWifi"
        static let streamingQualityCellular = "playback.streamingQualityCellular"
        static let forceDolbyVisionOnNonDVDisplay = "playback.forceDolbyVisionOnNonDVDisplay"
        static let enhancedUpscaling = "playback.enhancedUpscaling"
        static let lineArtUpscaling = "playback.lineArtUpscaling"
        static let showTopShelfRow = "appearance.showTopShelfRow"
        static let topShelfImage = "appearance.topShelfImage"
        static let speakerLayout = "playback.speakerLayout"
        static let dialogueBoost = "playback.dialogueBoost"
        static let nightMode = "playback.nightMode"
        static let nightModeStartHour = "playback.nightModeStartHour"
        static let nightModeEndHour = "playback.nightModeEndHour"
        static let lfeInStereoDownmix = "playback.lfeInStereoDownmix"
    }

    /// Stats panel "i" button. Read-only, so it is App Store safe and needs no diagnostic-build gate.
    var showStatsForNerds: Bool {
        didSet { store.set(showStatsForNerds, forKey: Keys.showStatsForNerds) }
    }

    var showEngineDiagnostics: Bool {
        didSet { store.set(showEngineDiagnostics, forKey: Keys.showEngineDiagnostics) }
    }

    /// ON = lossless FLAC for non-stream-copyable (TrueHD/DTS/DTS-HD MA/MP3/Opus), but AVPlayer decodes to LPCM, downmixed to stereo on stereo-only HDMI sinks. OFF (default) = lossy EAC3 5.1 384 kbps, works on all soundbars but caps 7.1->5.1. Recommend ON only with multichannel-LPCM AVR.
    var preferLosslessAudioBridge: Bool {
        didSet { store.set(preferLosslessAudioBridge, forKey: Keys.preferLosslessAudioBridge) }
    }

    /// AetherEngine#731 and #744, one switch for both formats, default ON. ON renders a TrueHD or DTS:X
    /// track's objects and heights into the `objectAudioLayout` bed, PCM over HDMI and APAC over AirPlay. A legacy-ARC sink
    /// takes only stereo PCM, so there it has to go OFF (with `preferLosslessAudioBridge`) to keep surround.
    /// OFF falls back to `preferLosslessAudioBridge`'s choice. A device value: it describes the speakers
    /// behind this box.
    var trueHDAtmosHeights: Bool {
        didSet { store.set(trueHDAtmosHeights, forKey: Keys.trueHDAtmosHeights) }
    }

    /// The bed `trueHDAtmosHeights` renders into, default 9.1.6. A 7.1.4 Denon fed the 9.1.6 bed through
    /// tvOS MAT played the side surrounds along with every height and rear-surround channel while the
    /// same file's DD+ Atmos track was clean (Discord, 2026-11-11), so the receiver's own layout is a
    /// choice. Kept apart from the switch so turning heights off and on again keeps the layout.
    var objectAudioLayout: SpatialSpeakerLayout {
        didSet { store.set(objectAudioLayout.rawValue, forKey: Keys.objectAudioLayout) }
    }

    /// iPhone player orientation (the in-player lock icon's remembered state): true pins the session
    /// (landscape at launch, current orientation when re-locked mid-play), false follows device rotation.
    /// iPad ignores it (never locked).
    var playerRotationLocked: Bool {
        didSet { store.set(playerRotationLocked, forKey: Keys.playerRotationLocked) }
    }

    /// Default forward-buffer depth for new VOD sessions (Issue #33); read into LoadOptions at load.
    var networkBufferDepth: PlaybackPreferences.NetworkBufferDepth {
        didSet { store.set(networkBufferDepth.rawValue, forKey: Keys.networkBufferDepth) }
    }

    var liveBufferDepth: PlaybackPreferences.LiveBufferDepth {
        didSet { store.set(liveBufferDepth.rawValue, forKey: Keys.liveBufferDepth) }
    }

    /// The link this box is on decides it, not the profile.
    var liveDelay: PlaybackPreferences.LiveDelay {
        didSet { store.set(liveDelay.rawValue, forKey: Keys.liveDelay) }
    }

    var liveTeletextPage: PlaybackPreferences.LiveTeletextPage {
        didSet { store.set(liveTeletextPage.rawValue, forKey: Keys.liveTeletextPage) }
    }

    /// Sodalite#87: the rung a VOD session starts on over Wi-Fi or Ethernet. On tvOS this is the only
    /// quality setting. A device value because it describes this box's line, not the viewer.
    var streamingQualityWifi: StreamingQuality {
        didSet { store.set(streamingQualityWifi.rawValue, forKey: Keys.streamingQualityWifi) }
    }

    /// Sodalite#87: the rung a VOD session starts on over cellular or an expensive path. iOS only in the UI.
    var streamingQualityCellular: StreamingQuality {
        didSet { store.set(streamingQualityCellular.rawValue, forKey: Keys.streamingQualityCellular) }
    }

    /// AetherEngine#455. On a display that reports no Dolby Vision, serve a Profile 8.1 source as a
    /// Profile 5 so AVPlayer composes the DV itself instead of the panel getting the static HDR10 base
    /// layer. Inert on a display that does Dolby Vision, which is why the settings row only appears on the
    /// displays it can act on.
    ///
    /// Default ON on tvOS since AetherEngine#1018: measured on an Apple TV 4K (tvOS 26.6 and 27.2) at an
    /// HDR10 panel, tvOS hands such a panel the base layer bit for bit and ignores the RPU (and with it the
    /// FEL curve fold), while this route applies it with unedited frames identical to the plain route. A
    /// stored value, set by the viewer, wins. Off elsewhere: every Mac reports no Dolby Vision display and
    /// already applies the RPU, so the masquerade buys nothing there.
    static var forceDolbyVisionOnNonDVDisplayDefault: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    var forceDolbyVisionOnNonDVDisplay: Bool {
        didSet { store.set(forceDolbyVisionOnNonDVDisplay, forKey: Keys.forceDolbyVisionOnNonDVDisplay) }
    }

    /// AetherEngine#846, default OFF. Upscales 8-bit SDR below 1080p on this device's GPU before it
    /// reaches the screen. A device value: what the hardware can afford is not the profile's business.
    var enhancedUpscaling: Bool {
        didSet { store.set(enhancedUpscaling, forKey: Keys.enhancedUpscaling) }
    }

    /// AetherEngine#1039, default OFF, read only while `enhancedUpscaling` is on: animated titles get the
    /// engine's line-art scaler, which also takes 1080p and 10-bit SDR. A device value like it.
    var lineArtUpscaling: Bool {
        didSet { store.set(lineArtUpscaling, forKey: Keys.lineArtUpscaling) }
    }

    /// tvOS Top Shelf row. On by default; see TopShelfEnabled for why it can be turned off at all.
    var showTopShelfRow: Bool {
        didSet { store.set(showTopShelfRow, forKey: Keys.showTopShelfRow) }
    }

    /// Picture on a Top Shelf cell. Its own setting rather than a reader of the row above, because
    /// a shelf cell is around 800pt wide against a 360pt card: a still that holds up in Continue
    /// Watching can be visibly soft up there, and a server's episode stills are capped at its
    /// image-extraction width. Defaults to the show's Thumb, not to the episode image the shelf drew
    /// before the setting existed: a server's Thumb is promo art and reliably large, while the
    /// stills vary per show, and a resume bar drawn across a soft one makes the softness worse
    /// rather than hiding it. Shows without a Thumb fall through to the backdrop, then the still.
    var topShelfImage: AppearancePreferences.ContinueWatchingImage {
        didSet { store.set(topShelfImage.rawValue, forKey: Keys.topShelfImage) }
    }

    /// AetherEngine#923: the most channels this box sends; see `AudioShapingSettings`.
    var speakerLayout: SpeakerLayout {
        didSet { store.set(speakerLayout.rawValue, forKey: Keys.speakerLayout) }
    }

    var dialogueBoost: DialogueBoost {
        didSet { store.set(dialogueBoost.rawValue, forKey: Keys.dialogueBoost) }
    }

    var nightMode: NightMode {
        didSet { store.set(nightMode.rawValue, forKey: Keys.nightMode) }
    }

    var nightModeStartHour: Int {
        didSet { store.set(nightModeStartHour, forKey: Keys.nightModeStartHour) }
    }

    var nightModeEndHour: Int {
        didSet { store.set(nightModeEndHour, forKey: Keys.nightModeEndHour) }
    }

    /// AetherEngine#1044: fold the LFE into the stereo downmix instead of dropping it.
    var lfeInStereoDownmix: Bool {
        didSet { store.set(lfeInStereoDownmix, forKey: Keys.lfeInStereoDownmix) }
    }

    var audioShapingSettings: AudioShapingSettings {
        AudioShapingSettings(speakers: speakerLayout, dialogue: dialogueBoost, nightMode: nightMode,
                             nightStartHour: nightModeStartHour, nightEndHour: nightModeEndHour,
                             lfeInStereoDownmix: lfeInStereoDownmix)
    }

    private let store: PreferenceKeyspace

    init(keyspace store: PreferenceKeyspace) {
        self.store = store
        self.showStatsForNerds = store.object(forKey: Keys.showStatsForNerds) as? Bool ?? false
        self.showEngineDiagnostics = store.object(forKey: Keys.showEngineDiagnostics) as? Bool ?? false
        self.preferLosslessAudioBridge = store.object(forKey: Keys.preferLosslessAudioBridge) as? Bool ?? false
        self.trueHDAtmosHeights = store.object(forKey: Keys.trueHDAtmosHeights) as? Bool ?? true
        self.objectAudioLayout = store.string(forKey: Keys.objectAudioLayout)
            .flatMap(SpatialSpeakerLayout.init(rawValue:)) ?? .l916
        self.playerRotationLocked = store.object(forKey: Keys.playerRotationLocked) as? Bool ?? true
        self.networkBufferDepth = store.string(forKey: Keys.networkBufferDepth)
            .flatMap(PlaybackPreferences.NetworkBufferDepth.init(rawValue:)) ?? .system
        self.liveBufferDepth = store.string(forKey: Keys.liveBufferDepth)
            .flatMap(PlaybackPreferences.LiveBufferDepth.init(rawValue:)) ?? .ninetyMinutes
        self.liveDelay = store.string(forKey: Keys.liveDelay)
            .flatMap(PlaybackPreferences.LiveDelay.init(rawValue:)) ?? .off
        self.liveTeletextPage = store.string(forKey: Keys.liveTeletextPage)
            .flatMap(PlaybackPreferences.LiveTeletextPage.init(rawValue:)) ?? .auto
        self.streamingQualityWifi = store.string(forKey: Keys.streamingQualityWifi)
            .flatMap(StreamingQuality.init(rawValue:)) ?? .original
        self.streamingQualityCellular = store.string(forKey: Keys.streamingQualityCellular)
            .flatMap(StreamingQuality.init(rawValue:)) ?? .original
        self.forceDolbyVisionOnNonDVDisplay = store.object(forKey: Keys.forceDolbyVisionOnNonDVDisplay) as? Bool
            ?? Self.forceDolbyVisionOnNonDVDisplayDefault
        self.enhancedUpscaling = store.object(forKey: Keys.enhancedUpscaling) as? Bool ?? false
        self.lineArtUpscaling = store.object(forKey: Keys.lineArtUpscaling) as? Bool ?? false
        self.showTopShelfRow = store.object(forKey: Keys.showTopShelfRow) as? Bool ?? true
        self.topShelfImage = store.string(forKey: Keys.topShelfImage)
            .flatMap(AppearancePreferences.ContinueWatchingImage.init(rawValue:)) ?? .thumb
        self.speakerLayout = store.string(forKey: Keys.speakerLayout).flatMap(SpeakerLayout.init(rawValue:)) ?? .auto
        self.dialogueBoost = store.string(forKey: Keys.dialogueBoost).flatMap(DialogueBoost.init(rawValue:)) ?? .off
        self.nightMode = store.string(forKey: Keys.nightMode).flatMap(NightMode.init(rawValue:)) ?? .off
        self.nightModeStartHour = (store.object(forKey: Keys.nightModeStartHour) as? Int).map { min(max($0, 0), 23) } ?? 22
        self.nightModeEndHour = (store.object(forKey: Keys.nightModeEndHour) as? Int).map { min(max($0, 0), 23) } ?? 7
        self.lfeInStereoDownmix = store.object(forKey: Keys.lfeInStereoDownmix) as? Bool ?? false
    }

    /// Reads every value again, for a factory reset that wiped the store underneath this object:
    /// it parsed its values once at launch. Assigned only where they differ, so observers see what
    /// changed (the Top Shelf bridge is keyed on `showTopShelfRow`) and a wiped key stays wiped.
    func reloadFromStore() {
        let stored = DevicePreferences(keyspace: store)
        func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<DevicePreferences, Value>) {
            if self[keyPath: path] != stored[keyPath: path] { self[keyPath: path] = stored[keyPath: path] }
        }
        update(\.showStatsForNerds)
        update(\.showEngineDiagnostics)
        update(\.preferLosslessAudioBridge)
        update(\.trueHDAtmosHeights)
        update(\.objectAudioLayout)
        update(\.playerRotationLocked)
        update(\.networkBufferDepth)
        update(\.liveBufferDepth)
        update(\.liveDelay)
        update(\.liveTeletextPage)
        update(\.streamingQualityWifi)
        update(\.streamingQualityCellular)
        update(\.forceDolbyVisionOnNonDVDisplay)
        update(\.enhancedUpscaling)
        update(\.lineArtUpscaling)
        update(\.showTopShelfRow)
        update(\.topShelfImage)
        update(\.speakerLayout)
        update(\.dialogueBoost)
        update(\.nightMode)
        update(\.nightModeStartHour)
        update(\.nightModeEndHour)
        update(\.lfeInStereoDownmix)
    }

    convenience init(store defaults: UserDefaults = .standard) {
        self.init(keyspace: PreferenceKeyspace(defaults: defaults, scope: nil))
    }
}
