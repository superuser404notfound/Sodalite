import Foundation
import Testing
@testable import Sodalite

@Suite("Profile sync payloads", .serialized)
@MainActor
struct ProfileSyncPayloadsTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profilePayloads.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func storedSettingNames(of store: Any) -> Set<String> {
        Set(
            Mirror(reflecting: store).children
                .compactMap(\.label)
                .filter { $0.hasPrefix("_") && $0 != "_$observationRegistrar" }
                .map { String($0.dropFirst()) }
        )
    }

    private func fields(_ payload: Any) -> Set<String> {
        CloudSyncForwardCompat.storedPropertyNames(of: payload).subtracting(["schemaVersion", "updatedAt"])
    }

    @Test func everyProfilePlaybackSettingIsInItsPayload() {
        let store = PlaybackPreferences(store: scratch("pb"))
        #expect(storedSettingNames(of: store) == fields(ProfilePlaybackPayload(collecting: store, stamp: .distantPast)))
    }

    @Test func everyProfileAppearanceSettingIsInItsPayload() {
        let store = AppearancePreferences(store: scratch("ap"))
        #expect(storedSettingNames(of: store) == fields(ProfileAppearancePayload(collecting: store, stamp: .distantPast)))
    }

    @Test func aProfilePayloadRoundTripsIntoAnotherProfile() throws {
        let defaults = scratch("roundTrip")
        let device = DevicePreferences(store: defaults)
        let source = PlaybackPreferences(store: defaults, scope: "s:a", device: device)
        source.preferredAudioLanguage = "ger"
        source.subtitleBackground = .outline
        source.nextEpisodeCountdownAnchor = .end
        let look = AppearancePreferences(store: defaults, scope: "s:a", device: device)
        look.hiddenTabs = [.catalog]
        look.navigationStyle = .sidebar
        look.uprightArtwork = .poster

        let data = try ProfileSyncPayload.playback(ProfilePlaybackPayload(collecting: source, stamp: .now)).encoded()
        let lookData = try ProfileSyncPayload.appearance(ProfileAppearancePayload(collecting: look, stamp: .now)).encoded()
        let target = PlaybackPreferences(store: defaults, scope: "s:b", device: device)
        let targetLook = AppearancePreferences(store: defaults, scope: "s:b", device: device)
        guard case .playback(let decoded) = try ProfileSyncPayload.decode(data, kind: .playback),
              case .appearance(let decodedLook) = try ProfileSyncPayload.decode(lookData, kind: .appearance)
        else { Issue.record("wrong case"); return }
        decoded.apply(to: target)
        decodedLook.apply(to: targetLook)

        #expect(target.preferredAudioLanguage == "ger")
        #expect(target.subtitleBackground == .outline)
        #expect(target.nextEpisodeCountdownAnchor == .end)
        #expect(targetLook.hiddenTabs == [.catalog])
        #expect(targetLook.navigationStyle == .sidebar)
        #expect(targetLook.uprightArtwork == .poster)
    }

    @Test func theUprightArtworkDefaultsToTheBackdrop() {
        #expect(AppearancePreferences(store: scratch("uprightDefault")).uprightArtwork == .backdrop)
    }

    /// The keys each profile record carried when it first shipped (aca3e7a7, 2026-09-17). A record
    /// from that build must decode on every later one, so a field added since has to be Optional:
    /// `touchpadScrubbing` was not, and one profile's playback record was skipped on every device
    /// from then on. Never add a key here; a new field is exactly what this list must NOT contain.
    private static let firstShippedKeys: [ProfileRecordKind: Set<String>] = [
        .playback: [
            "schemaVersion", "updatedAt", "autoplayNextEpisode", "autoplayCountdown", "autoSkipIntro",
            "autoSkipRecap", "autoSkipOutro", "nextEpisodeCountdownSeconds", "nextEpisodeCountdownAnchor",
            "skipForwardSeconds", "skipBackwardSeconds", "preferredAudioLanguage", "preferredSubtitleLanguage",
            "autoSubtitleForForeignAudio", "autoForcedSubtitles", "styledASSSubtitles", "subtitleFontSize",
            "subtitleColor", "subtitleBackground", "subtitleDelaySeconds", "subtitleVerticalPosition",
            "subtitleFont", "subtitleWeight", "pictureMode", "showScrubPreview", "preferServerTrickplay",
            "rememberTrackSelections", "subtitlesOnSkipBack",
        ],
        .appearance: [
            "schemaVersion", "updatedAt", "accentChoice", "backgroundStyle", "showContentLogos",
            "continueWatchingImage", "largeCards", "nowPlayingUsesSeriesPoster", "spoilerProtectionEnabled",
            "spoilerHideEpisodes", "spoilerHideMovies", "hiddenTabs", "navigationStyle", "showPosterBadges",
            "showDetailBadges", "showLibraryNames", "showPosterProgress", "showCommunityRating",
            "showCriticRating",
        ],
        .home: [
            "schemaVersion", "updatedAt", "configsJSON", "mergeCWNextUp", "rewatchNextUp",
            "collectionGrouping", "librarySorts",
        ],
    ]

    private func currentPayload(_ kind: ProfileRecordKind) -> ProfileSyncPayload {
        let defaults = scratch("firstShipped-\(kind.rawValue)")
        switch kind {
        case .playback:
            // The Optionals set, so no key is missing from the encoding for being nil.
            let store = PlaybackPreferences(store: defaults)
            store.preferredAudioLanguage = "ger"
            store.preferredSubtitleLanguage = "eng"
            return .playback(ProfilePlaybackPayload(collecting: store, stamp: .now))
        case .appearance:
            return .appearance(ProfileAppearancePayload(collecting: AppearancePreferences(store: defaults), stamp: .now))
        case .home:
            return .home(ProfileHomePayload(
                updatedAt: .now, configsJSON: Data("[]".utf8), mergeCWNextUp: true, rewatchNextUp: false,
                collectionGrouping: "auto", librarySorts: ["lib": "name"]
            ))
        }
    }

    @Test("a record from the first shipped build still decodes", arguments: ProfileRecordKind.allCases)
    func firstShippedRecordDecodes(kind: ProfileRecordKind) throws {
        let current = try #require(
            JSONSerialization.jsonObject(with: currentPayload(kind).encoded()) as? [String: Any]
        )
        let firstShipped = try #require(Self.firstShippedKeys[kind])
        #expect(firstShipped.isSubset(of: Set(current.keys)), "a first-shipped key was renamed or dropped")

        let old = try JSONSerialization.data(withJSONObject: current.filter { firstShipped.contains($0.key) })

        do {
            _ = try ProfileSyncPayload.decode(old, kind: kind)
        } catch {
            Issue.record("\(kind.rawValue): \(CloudSyncService.decodeFailure(error)); a field added later must be Optional")
        }
    }

    @Test func aRecordWithoutTouchpadScrubbingKeepsTheLocalValue() throws {
        let store = PlaybackPreferences(store: scratch("noTouchpad"))
        store.touchpadScrubbing = false
        var payload = ProfilePlaybackPayload(collecting: store, stamp: .now)
        payload.touchpadScrubbing = nil
        payload.skipForwardSeconds = 45

        payload.apply(to: store)

        #expect(!store.touchpadScrubbing)
        #expect(store.skipForwardSeconds == 45)
    }

    @Test func aRecordWithoutTheCardSwitchKeepsTheLocalValue() {
        let store = PlaybackPreferences(store: scratch("noCardSwitch"))
        store.showNextEpisodeCard = false
        var payload = ProfilePlaybackPayload(collecting: store, stamp: .now)
        payload.showNextEpisodeCard = nil

        payload.apply(to: store)

        #expect(!store.showNextEpisodeCard)
    }

    @Test func theRatingPromptSwitchTravelsAndAnOlderRecordKeepsIt() {
        let source = PlaybackPreferences(store: scratch("ratingPromptSource"))
        source.askForRatingAfterMovie = false
        let target = PlaybackPreferences(store: scratch("ratingPromptTarget"))
        ProfilePlaybackPayload(collecting: source, stamp: .now).apply(to: target)
        #expect(!target.askForRatingAfterMovie)

        var older = ProfilePlaybackPayload(collecting: source, stamp: .now)
        older.askForRatingAfterMovie = nil
        target.askForRatingAfterMovie = true
        older.apply(to: target)
        #expect(target.askForRatingAfterMovie)
    }

    @Test func theVersionOrderTravelsAndAnOlderRecordKeepsIt() {
        let source = PlaybackPreferences(store: scratch("versionOrderSource"))
        source.versionOrder = .server
        let target = PlaybackPreferences(store: scratch("versionOrderTarget"))
        ProfilePlaybackPayload(collecting: source, stamp: .now).apply(to: target)
        #expect(target.versionOrder == .server)

        var older = ProfilePlaybackPayload(collecting: source, stamp: .now)
        older.versionOrder = nil
        target.versionOrder = .quality
        older.apply(to: target)
        #expect(target.versionOrder == .quality)
    }

    @Test func aDecodeFailureNamesTheKeyAndNoValue() {
        let data = Data(#"{"schemaVersion":1,"secret":"hunter2"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(ProfileHomePayload.self, from: data)
            Issue.record("decoded without its required keys")
        } catch {
            let text = CloudSyncService.decodeFailure(error)
            #expect(text.hasPrefix("missing "))
            #expect(!text.contains("hunter2"))
        }
    }

    @Test func anUnknownRawValueKeepsTheCurrentValue() {
        let store = PlaybackPreferences(store: scratch("unknown"))
        store.subtitleColor = .yellow
        var payload = ProfilePlaybackPayload(collecting: store, stamp: .now)
        payload.subtitleColor = "ultraviolet"

        payload.apply(to: store)

        #expect(store.subtitleColor == .yellow)
    }

    @Test func onlyPlaybackAndAppearanceAreProfileBacked() {
        #expect(CloudSyncStoreKey.allCases.filter(\.isProfileBacked) == [.playback, .appearance])
        #expect(ProfileRecordKind.playback.legacyStoreKey == .playback)
        #expect(ProfileRecordKind.appearance.legacyStoreKey == .appearance)
        #expect(ProfileRecordKind.home.legacyStoreKey == nil)
    }
}
