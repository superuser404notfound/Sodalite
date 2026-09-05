import Testing
import Foundation
@testable import Sodalite

/// Sodalite#114. Default ON: the touch surface has always scrubbed, and the switch exists for the
/// people who drive the box by clicking the ring and keep brushing the pad by accident.
struct TouchpadScrubbingPreferenceTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "TouchpadScrubbingPreferenceTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test func defaultsToOn() {
        #expect(PlaybackPreferences(store: defaults(#function)).touchpadScrubbing)
    }

    @Test func persistsAcrossInstances() {
        let store = defaults(#function)
        let a = PlaybackPreferences(store: store)
        a.touchpadScrubbing = false
        let b = PlaybackPreferences(store: store)
        #expect(!b.touchpadScrubbing)
    }
}
