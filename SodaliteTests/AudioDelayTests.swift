import Testing
import Foundation
@testable import Sodalite

/// The audio delay is one device value in milliseconds (AetherEngine#464): Settings picks it from
/// `choices`, the player's audio menu steps it, and both land on the same 25 ms grid.
@MainActor
struct AudioDelayTests {

    @Test("the choices run from -500 to +500 ms in 25 ms steps, with 0 among them")
    func choices() {
        #expect(AudioDelay.choices.first == -500)
        #expect(AudioDelay.choices.last == 500)
        #expect(AudioDelay.choices.count == 41)
        #expect(AudioDelay.choices.contains(0))
    }

    @Test("a step moves one grid place and stops at both ends")
    func stepping() {
        #expect(AudioDelay.stepped(0, by: 1) == 25)
        #expect(AudioDelay.stepped(150, by: -2) == 100)
        #expect(AudioDelay.stepped(500, by: 1) == 500)
        #expect(AudioDelay.stepped(-500, by: -3) == -500)
        // A value off the grid (written by hand into defaults) snaps first.
        #expect(AudioDelay.stepped(160, by: 0) == 150)
    }

    @Test("the label keeps the sign, so plus reads as later")
    func labels() {
        #expect(AudioDelay.label(0) == "0 ms")
        #expect(AudioDelay.label(150) == "+150 ms")
        #expect(AudioDelay.label(-75) == "-75 ms")
    }

    @Test("the engine gets seconds, clamped to the offered range")
    func seconds() {
        #expect(AudioDelay.seconds(175) == 0.175)
        #expect(AudioDelay.seconds(-2000) == -0.5)
    }

    @Test("the value persists per device and a stored one out of range is clamped")
    func persistence() {
        let defaults = UserDefaults(suiteName: "AudioDelayTests-\(UUID().uuidString)")!
        let prefs = DevicePreferences(store: defaults)
        #expect(prefs.audioDelayMilliseconds == 0)
        prefs.audioDelayMilliseconds = 150
        #expect(DevicePreferences(store: defaults).audioDelayMilliseconds == 150)
        defaults.set(5000, forKey: "playback.audioDelayMilliseconds")
        #expect(DevicePreferences(store: defaults).audioDelayMilliseconds == 500)
    }
}
