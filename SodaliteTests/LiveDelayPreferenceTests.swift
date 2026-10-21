import Foundation
import Testing
@testable import Sodalite

@Suite("Live delay setting", .serialized)
@MainActor
struct LiveDelayPreferenceTests {

    private func scratchDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "liveDelay.tests")!
        defaults.removePersistentDomain(forName: "liveDelay.tests")
        return defaults
    }

    @Test func offHandsTheEngineNoCushion() {
        #expect(PlaybackPreferences.LiveDelay.off.seconds == nil)
        #expect(PlaybackPreferences.LiveDelay.allCases.compactMap(\.seconds) == [10, 20, 30, 45])
    }

    @Test func defaultsToOffAndPersistsPerDevice() {
        let defaults = scratchDefaults()
        #expect(DevicePreferences(store: defaults).liveDelay == .off)
        DevicePreferences(store: defaults).liveDelay = .thirtySeconds
        #expect(DevicePreferences(store: defaults).liveDelay == .thirtySeconds)
    }
}
