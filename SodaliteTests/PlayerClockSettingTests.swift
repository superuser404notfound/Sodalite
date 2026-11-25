import Testing
import Foundation
@testable import Sodalite

@MainActor
struct PlayerClockSettingTests {
    private func scratch(_ name: String) -> PlaybackPreferences {
        PlaybackPreferences(store: UserDefaults(suiteName: "test.playerClock.\(name).\(UUID())")!)
    }

    @Test("the clock and end time show by default")
    func showPlayerClockDefaultsOn() {
        #expect(scratch("default").showPlayerClock)
    }

    @Test("the switch persists in its own key")
    func showPlayerClockPersists() {
        let defaults = UserDefaults(suiteName: "test.playerClock.persist.\(UUID())")!
        PlaybackPreferences(store: defaults).showPlayerClock = false
        #expect(!PlaybackPreferences(store: defaults).showPlayerClock)
    }

    @Test("the profile record carries the switch to another device")
    func showPlayerClockRoundTrips() {
        let source = scratch("source")
        source.showPlayerClock = false
        let payload = ProfilePlaybackPayload(collecting: source, stamp: .now)
        #expect(payload.showPlayerClock == false)
        let target = scratch("target")
        payload.apply(to: target)
        #expect(!target.showPlayerClock)
    }

    @Test("a record from a build before the switch keeps the local value")
    func nilShowPlayerClockKeepsLocal() {
        var payload = ProfilePlaybackPayload(collecting: scratch("old"), stamp: .now)
        payload.showPlayerClock = nil
        let target = scratch("local")
        target.showPlayerClock = false
        payload.apply(to: target)
        #expect(!target.showPlayerClock)
    }
}
