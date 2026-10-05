import Foundation
import Testing
@testable import Sodalite

/// A setting that never made it into a payload does not sync, and nothing says so: it looks exactly
/// like sync being broken. That is what the OLED background did in 1.0.0 (Sodalite#45, the reporter
/// spent a round on it), and `liveTeletextPage` plus `profileReprompt` had drifted out the same way.
/// So pin the two sides against each other: every stored setting of a synced store must appear in
/// its payload, with every exemption named here on purpose.
@Suite("CloudSync settings parity", .serialized)
@MainActor
struct CloudSyncSettingsParityTests {

    /// Stored property names of an @Observable store, minus the macro's registrar and the
    /// UserDefaults handle. The macro backs each stored property with an underscored field.
    private func storedSettingNames(of store: Any) -> Set<String> {
        Set(
            Mirror(reflecting: store).children
                .compactMap(\.label)
                .filter { $0.hasPrefix("_") && $0 != "_$observationRegistrar" }
                .map { String($0.dropFirst()) }
        )
    }

    private func payloadFieldNames(_ key: CloudSyncStoreKey) -> Set<String> {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        return container.collectSettingsPayload(key, stamp: .distantPast)
            .knownFields
            .subtracting(["schemaVersion", "updatedAt"])
    }

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "parity.\(name)")!
        defaults.removePersistentDomain(forName: "parity.\(name)")
        return defaults
    }

    /// The legacy playback record still carries every value it carried before per-profile settings:
    /// the profile values of the store plus the device values passed through it. Nothing may sit in
    /// both, and every device value has to land in exactly one of the two legacy records.
    ///
    /// Named exemptions, all still written for older decoders and no longer settings this build
    /// stores: `skipIntervalSeconds` is the pre-split single interval (Sodalite#144), the two
    /// overlay flags are required by 1.0.0's synthesized decoder.
    @Test func everyPlaybackSettingIsInThePayload() {
        let defaults = scratchDefaults("playback")
        let device = storedSettingNames(of: DevicePreferences(store: defaults))
        let profile = storedSettingNames(of: PlaybackPreferences(store: defaults))
        let payload = payloadFieldNames(.playback)
            .subtracting(["skipIntervalSeconds", "showDiagnosticOverlay", "focusDiagnosticOverlayOnDV"])
        #expect(profile.isDisjoint(with: device))
        #expect(profile.union(device.intersection(payload)) == payload)
    }

    @Test func everyAppearanceSettingIsInThePayload() {
        let defaults = scratchDefaults("appearance")
        let device = storedSettingNames(of: DevicePreferences(store: defaults))
        let profile = storedSettingNames(of: AppearancePreferences(store: defaults))
        let payload = payloadFieldNames(.appearance)
        #expect(profile.isDisjoint(with: device))
        #expect(profile.union(device.intersection(payload)) == payload)
    }

    /// Named exemptions: the two streaming-quality rungs (Sodalite#87) postdate the legacy records.
    /// Those records exist only for builds that already read them, and no such build knows a rung.
    @Test func everyDeviceValueTravelsInOneLegacyRecord() {
        let device = storedSettingNames(of: DevicePreferences(store: scratchDefaults("device")))
            .subtracting(["streamingQualityWifi", "streamingQualityCellular"])
        let playback = device.intersection(payloadFieldNames(.playback))
        let appearance = device.intersection(payloadFieldNames(.appearance))
        #expect(playback.isDisjoint(with: appearance))
        #expect(playback.union(appearance) == device)
    }

    /// Two named exemptions: `defaultUserIDRevision` is an observation counter rather than a
    /// setting, and the payload's `defaultUserID` is the retired global pin, still written for
    /// older builds and deliberately never applied.
    ///
    /// `forgottenServers` is a third shape: it lives in UserDefaults behind a computed property, so
    /// the mirror sees only the counter that makes it observable. Substituted rather than exempted,
    /// so the payload side stays under the same check as every other setting.
    @Test func everyAuthSettingIsInThePayload() {
        let store = AuthPreferences(store: scratchDefaults("auth"))
        var stored = storedSettingNames(of: store).subtracting(["defaultUserIDRevision"])
        if stored.remove("forgottenServersRevision") != nil { stored.insert("forgottenServers") }
        #expect(stored == payloadFieldNames(.auth).subtracting(["defaultUserID"]))
    }

    @Test func everySeerrNotificationSettingIsInThePayload() {
        let store = SeerrNotificationPreferences(defaults: scratchDefaults("seerr"))
        // The my-requests switch is per profile and device-local by design; its revision only re-renders rows.
        let stored = storedSettingNames(of: store).subtracting(["myRequestsRevision"])
        #expect(stored == payloadFieldNames(.seerrNotifications))
    }

    @Test func everyParentalControlsSettingIsInThePayload() {
        let store = ParentalControlsPreferences(store: scratchDefaults("parental"))
        #expect(storedSettingNames(of: store) == payloadFieldNames(.parentalControls))
    }

    /// The other store keys are per-entry memories, not preference stores: their payload is one
    /// `entries` map that CloudSyncMerge merges per key, so there is no field list to keep in step.
    @Test func theMemoryStoresAreCoveredByTheirPerKeyMerge() {
        #expect(payloadFieldNames(.trackMemory) == ["entries"])
        #expect(payloadFieldNames(.spoilerReveals) == ["entries"])
        #expect(payloadFieldNames(.spoilerSeriesRules) == ["entries"])
    }
}
