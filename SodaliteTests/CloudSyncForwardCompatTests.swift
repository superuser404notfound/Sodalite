import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync cross-version field carrying")
struct CloudSyncForwardCompatTests {

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func object(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// The live case: 1.0.0 does not know the three spoiler fields a current build writes, and
    /// without carrying them its next upload hands every newer device a reset.
    @Test("fields the build cannot write are carried and re-attached")
    func unknownFieldsSurviveAnOlderBuildsUpload() {
        let remote = Self.json([
            "schemaVersion": 3,
            "accentChoice": "orange",
            "spoilerProtectionEnabled": true,
            "spoilerHideEpisodes": false,
        ])
        let known: Set<String> = ["schemaVersion", "accentChoice"]

        let carried = CloudSyncForwardCompat.unknownFields(remote: remote, known: known)
        let upload = Self.object(CloudSyncForwardCompat.merged(
            local: Self.json(["schemaVersion": 2, "accentChoice": "systemBlue"]),
            carrying: carried
        ))

        #expect(upload["accentChoice"] as? String == "systemBlue")
        #expect(upload["spoilerProtectionEnabled"] as? Bool == true)
        #expect(upload["spoilerHideEpisodes"] as? Bool == false)
        #expect(upload["schemaVersion"] as? Int == 3)
    }

    /// The trap this design has to avoid: a known optional that is nil right now is missing from
    /// the JSON, and treating that as a field from the future would resurrect the value the user
    /// just cleared, on every upload, forever.
    @Test("a known field that is currently nil is never carried")
    func clearedOptionalsAreNotResurrected() {
        let remote = Self.json(["schemaVersion": 1, "launchBehavior": "picker", "defaultServerID": "abc"])
        let known: Set<String> = ["schemaVersion", "launchBehavior", "defaultUserID", "defaultServerID"]

        let carried = CloudSyncForwardCompat.unknownFields(remote: remote, known: known)
        #expect(carried == nil)

        let cleared = Self.json(["schemaVersion": 1, "launchBehavior": "picker"])
        #expect(Self.object(CloudSyncForwardCompat.merged(local: cleared, carrying: carried))["defaultServerID"] == nil)
    }

    @Test("what this build writes always wins over what it carries")
    func localValuesWin() {
        let carried = CloudSyncForwardCompat.unknownFields(
            remote: Self.json(["schemaVersion": 3, "accentChoice": "orange", "future": 1]),
            known: ["schemaVersion"]
        )
        let upload = Self.object(CloudSyncForwardCompat.merged(
            local: Self.json(["schemaVersion": 3, "accentChoice": "systemBlue"]),
            carrying: carried
        ))
        #expect(upload["accentChoice"] as? String == "systemBlue")
        #expect(upload["future"] as? Int == 1)
    }

    @Test("a carried blob never drags the schema version backwards")
    func carriedVersionNeverDowngrades() {
        let carried = Self.json(["schemaVersion": 1, "legacy": true])
        let upload = Self.object(CloudSyncForwardCompat.merged(
            local: Self.json(["schemaVersion": 3, "accentChoice": "orange"]),
            carrying: carried
        ))
        #expect(upload["schemaVersion"] as? Int == 3)
    }

    @Test("nothing to carry and malformed input leave the payload untouched")
    func degradesToTheLocalPayload() {
        let local = Self.json(["schemaVersion": 1, "notifyPendingRequests": true])
        #expect(CloudSyncForwardCompat.unknownFields(remote: Data("nonsense".utf8), known: []) == nil)
        #expect(CloudSyncForwardCompat.merged(local: local, carrying: nil) == local)
        #expect(CloudSyncForwardCompat.merged(local: local, carrying: Data("nonsense".utf8)) == local)
    }

    /// The whole mechanism rests on stored property names being the coding keys. If a payload ever
    /// grows a custom CodingKeys mapping, the carrying would silently start treating its own
    /// fields as fields from the future, so pin it here rather than finding out on a device.
    @Test("every settings payload encodes exactly the fields it declares", arguments: CloudSyncStoreKey.allCases)
    func storedPropertyNamesMatchTheEncodedKeys(key: CloudSyncStoreKey) throws {
        let payload = Self.samplePayload(for: key)
        let encoded = Self.object(try payload.encoded())
        #expect(Set(encoded.keys) == payload.knownFields, "\(key.rawValue) encodes keys it does not declare")
    }

    /// Every optional is populated so a nil cannot hide a key from the comparison above.
    private static func samplePayload(for key: CloudSyncStoreKey) -> SettingsSyncPayload {
        let stamp = Date(timeIntervalSince1970: 1)
        switch key {
        case .playback:
            return .playback(PlaybackSettingsPayload(
                updatedAt: stamp,
                autoplayNextEpisode: true, autoSkipIntro: true, autoSkipOutro: true,
                nextEpisodeCountdownSeconds: 10, skipIntervalSeconds: 10,
                preferredAudioLanguage: "de", preferredSubtitleLanguage: "en",
                autoSubtitleForForeignAudio: true, styledASSSubtitles: true,
                subtitleFontSize: "medium", subtitleColor: "white", subtitleBackground: "none",
                subtitleDelaySeconds: 0, subtitleVerticalPosition: "bottom",
                subtitleFont: "system", subtitleWeight: "regular", pictureMode: "standard",
                showStatsForNerds: false, showEngineDiagnostics: false, preferLosslessAudioBridge: false,
                showScrubPreview: true, preferServerTrickplay: true,
                playerRotationLocked: false, networkBufferDepth: "balanced",
                rememberTrackSelections: true, autoForcedSubtitles: true,
                autoSkipRecap: true,
                subtitlesOnSkipBack: true, liveTeletextPage: "auto", autoplayCountdown: true,
                forceDolbyVisionOnNonDVDisplay: true, touchpadScrubbing: true
            ))
        case .appearance:
            return .appearance(AppearanceSettingsPayload(
                updatedAt: stamp, accentChoice: "orange", backgroundStyle: "graphiteGlass",
                showContentLogos: true, continueWatchingImage: "thumb", largeCards: false,
                nowPlayingUsesSeriesPoster: false, hiddenTabs: ["catalog"]
            ))
        case .auth:
            return .auth(AuthSettingsPayload(
                updatedAt: stamp, launchBehavior: "picker", defaultUserID: "u", defaultServerID: "s",
                profileReprompt: "off"
            ))
        case .seerrNotifications:
            return .seerrNotifications(SeerrNotificationSettingsPayload(updatedAt: stamp, notifyPendingRequests: true))
        case .parentalControls:
            return .parentalControls(ParentalControlsSettingsPayload(updatedAt: stamp, protectedProfileIDs: ["a"]))
        case .trackMemory:
            return .trackMemory(TrackMemoryPayload(updatedAt: stamp, entries: [:]))
        case .spoilerReveals:
            return .spoilerReveals(SpoilerRevealPayload(updatedAt: stamp, entries: [:]))
        case .spoilerSeriesRules:
            return .spoilerSeriesRules(SpoilerSeriesRulesPayload(updatedAt: stamp, entries: [:]))
        }
    }
}
