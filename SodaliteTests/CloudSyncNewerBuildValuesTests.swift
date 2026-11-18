import Foundation
import Testing
@testable import Sodalite

/// Values a newer build writes that this one does not know. They must neither fail a record nor be
/// lost on this device's next upload.
@Suite("CloudSync survives values from newer builds", .serialized)
@MainActor
struct CloudSyncNewerBuildValuesTests {
    private func appearance(_ name: String) -> AppearancePreferences {
        let suite = "newerValues.\(name).\(UUID().uuidString)"
        return AppearancePreferences(store: UserDefaults(suiteName: suite)!)
    }

    @Test func aHiddenTabThisBuildDoesNotKnowIsWrittenBack() {
        let store = appearance("tabs")
        let hideable = AppTab.allCases.first(where: \.isHideable)!

        store.applySyncedHiddenTabs([hideable.rawValue, "podcasts"])

        #expect(store.hiddenTabs == [hideable])
        #expect(store.syncedHiddenTabs == [hideable.rawValue, "podcasts"].sorted())
    }

    @Test func aTrackMemoryRecordWithOneUnknownEntryKeepsTheRest() throws {
        let json = #"""
        {"schemaVersion":1,"updatedAt":1000,"entries":{
          "good":{"subtitle":{"off":{}},"updatedAt":1000},
          "future":{"subtitle":{"hologram":{"depth":3}},"updatedAt":1000}
        }}
        """#
        let payload = try JSONDecoder().decode(TrackMemoryPayload.self, from: Data(json.utf8))

        #expect(Set(payload.entries.keys) == ["good"])
        #expect(payload.entries["good"]?.subtitle == .off)
    }

    @Test func aSeriesRuleFromANewerBuildDoesNotFailTheRecord() throws {
        let json = #"""
        {"schemaVersion":1,"updatedAt":1000,"entries":{
          "a":{"rule":"hidden","updatedAt":1000},
          "b":{"rule":"blurred","updatedAt":1000}
        }}
        """#
        let payload = try JSONDecoder().decode(SpoilerSeriesRulesPayload.self, from: Data(json.utf8))

        #expect(payload.entries.keys.sorted() == ["a"])
        #expect(payload.entries["a"]?.rule == .hidden)
    }

    @Test func theLossyDecodeStillRoundTrips() throws {
        let payload = SpoilerSeriesRulesPayload(
            updatedAt: Date(timeIntervalSince1970: 5),
            entries: ["x": SpoilerSeriesRuleEntry(rule: .shown, updatedAt: Date(timeIntervalSince1970: 5))]
        )
        let decoded = try JSONDecoder().decode(SpoilerSeriesRulesPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)
    }
}

extension CloudSyncNewerBuildValuesTests {
    /// After an update that teaches this build the tab, it must count as hidden here too, and unhiding
    /// it must stick across a relaunch.
    @Test func aTabThisBuildLearnsJoinsTheKnownOnes() {
        let suite = "newerValues.learned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hideable = AppTab.allCases.first(where: \.isHideable)!
        defaults.set([hideable.rawValue, "podcasts"], forKey: "appearance.hiddenTabs.newerBuilds")

        let store = AppearancePreferences(store: defaults)
        #expect(store.hiddenTabs.contains(hideable))
        #expect(store.hiddenTabsFromNewerBuilds == ["podcasts"])
        #expect(store.syncedHiddenTabs.filter { $0 == hideable.rawValue }.count == 1)

        store.setHiddenTabs(store.hiddenTabs.subtracting([hideable]))
        #expect(!AppearancePreferences(store: defaults).hiddenTabs.contains(hideable))
    }
}
