import Foundation
import Observation

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
        static let playerRotationLocked = "playback.playerRotationLocked"
        static let networkBufferDepth = "playback.networkBufferDepth"
        static let liveBufferDepth = "playback.liveBufferDepth"
        static let liveTeletextPage = "playback.liveTeletextPage"
        static let streamingQualityWifi = "playback.streamingQualityWifi"
        static let streamingQualityCellular = "playback.streamingQualityCellular"
        static let forceDolbyVisionOnNonDVDisplay = "playback.forceDolbyVisionOnNonDVDisplay"
        static let showTopShelfRow = "appearance.showTopShelfRow"
        static let topShelfImage = "appearance.topShelfImage"
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

    /// AetherEngine#455, experimental, default OFF. On a display that reports no Dolby Vision, serve a
    /// Profile 8.1 source as a Profile 5 so AVPlayer composes the DV itself instead of the panel getting
    /// the static HDR10 base layer. Inert on a display that does Dolby Vision, which is why the settings
    /// row only appears on the displays it can act on.
    var forceDolbyVisionOnNonDVDisplay: Bool {
        didSet { store.set(forceDolbyVisionOnNonDVDisplay, forKey: Keys.forceDolbyVisionOnNonDVDisplay) }
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

    private let store: PreferenceKeyspace

    init(keyspace store: PreferenceKeyspace) {
        self.store = store
        self.showStatsForNerds = store.object(forKey: Keys.showStatsForNerds) as? Bool ?? false
        self.showEngineDiagnostics = store.object(forKey: Keys.showEngineDiagnostics) as? Bool ?? false
        self.preferLosslessAudioBridge = store.object(forKey: Keys.preferLosslessAudioBridge) as? Bool ?? false
        self.playerRotationLocked = store.object(forKey: Keys.playerRotationLocked) as? Bool ?? true
        self.networkBufferDepth = store.string(forKey: Keys.networkBufferDepth)
            .flatMap(PlaybackPreferences.NetworkBufferDepth.init(rawValue:)) ?? .system
        self.liveBufferDepth = store.string(forKey: Keys.liveBufferDepth)
            .flatMap(PlaybackPreferences.LiveBufferDepth.init(rawValue:)) ?? .ninetyMinutes
        self.liveTeletextPage = store.string(forKey: Keys.liveTeletextPage)
            .flatMap(PlaybackPreferences.LiveTeletextPage.init(rawValue:)) ?? .auto
        self.streamingQualityWifi = store.string(forKey: Keys.streamingQualityWifi)
            .flatMap(StreamingQuality.init(rawValue:)) ?? .original
        self.streamingQualityCellular = store.string(forKey: Keys.streamingQualityCellular)
            .flatMap(StreamingQuality.init(rawValue:)) ?? .original
        self.forceDolbyVisionOnNonDVDisplay = store.object(forKey: Keys.forceDolbyVisionOnNonDVDisplay) as? Bool ?? false
        self.showTopShelfRow = store.object(forKey: Keys.showTopShelfRow) as? Bool ?? true
        self.topShelfImage = store.string(forKey: Keys.topShelfImage)
            .flatMap(AppearancePreferences.ContinueWatchingImage.init(rawValue:)) ?? .thumb
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
        update(\.playerRotationLocked)
        update(\.networkBufferDepth)
        update(\.liveBufferDepth)
        update(\.liveTeletextPage)
        update(\.streamingQualityWifi)
        update(\.streamingQualityCellular)
        update(\.forceDolbyVisionOnNonDVDisplay)
        update(\.showTopShelfRow)
        update(\.topShelfImage)
    }

    convenience init(store defaults: UserDefaults = .standard) {
        self.init(keyspace: PreferenceKeyspace(defaults: defaults, scope: nil))
    }
}
