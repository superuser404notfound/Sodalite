import Testing
import Foundation
@testable import Sodalite

@MainActor
struct PrerollSettingTests {
    private func scratch(_ name: String) -> PlaybackPreferences {
        PlaybackPreferences(store: UserDefaults(suiteName: "test.preroll.\(name).\(UUID())")!)
    }

    @Test("pre-rolls play by default, like Jellyfin-Web's cinema mode")
    func playPrerollsDefaultsOn() {
        #expect(scratch("default").playPrerolls)
    }

    @Test("the switch persists in its own key")
    func playPrerollsPersists() {
        let defaults = UserDefaults(suiteName: "test.preroll.persist.\(UUID())")!
        PlaybackPreferences(store: defaults).playPrerolls = false
        #expect(!PlaybackPreferences(store: defaults).playPrerolls)
    }

    @Test("the profile record carries the switch to another device")
    func playPrerollsRoundTrips() {
        let source = scratch("source")
        source.playPrerolls = false
        let payload = ProfilePlaybackPayload(collecting: source, stamp: .now)
        #expect(payload.playPrerolls == false)
        let target = scratch("target")
        payload.apply(to: target)
        #expect(!target.playPrerolls)
    }

    @Test("a record from a build before the switch keeps the local value")
    func nilPlayPrerollsKeepsLocal() {
        var payload = ProfilePlaybackPayload(collecting: scratch("old"), stamp: .now)
        payload.playPrerolls = nil
        let target = scratch("local")
        target.playPrerolls = false
        payload.apply(to: target)
        #expect(!target.playPrerolls)
    }
}
