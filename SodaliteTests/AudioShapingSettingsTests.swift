import Foundation
import Testing
import AetherEngine
@testable import Sodalite

@Suite("Audio shaping settings (AetherEngine#923)")
@MainActor
struct AudioShapingSettingsTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: hour, minute: 30))!
    }

    @Test("the defaults shape nothing")
    func defaultsAreInactive() {
        #expect(!AudioShapingSettings().shaping(at: at(hour: 23), calendar: calendar).isActive)
    }

    @Test("each setting maps onto the engine value")
    func mapping() {
        let s = AudioShapingSettings(speakers: .stereo, dialogue: .medium, nightMode: .on)
        let shaping = s.shaping(at: at(hour: 12), calendar: calendar)
        #expect(shaping.maxChannels == 2)
        #expect(shaping.dialogueGainDB == 6)
        #expect(shaping.compressor == .night)
        #expect(SpeakerLayout.surround51.maxChannels == 6)
        #expect(SpeakerLayout.auto.maxChannels == nil)
    }

    @Test("a schedule across midnight is on late and early, off in the day")
    func scheduleAcrossMidnight() {
        let s = AudioShapingSettings(nightMode: .scheduled, nightStartHour: 22, nightEndHour: 7)
        #expect(s.nightModeActive(at: at(hour: 22), calendar: calendar))
        #expect(s.nightModeActive(at: at(hour: 3), calendar: calendar))
        #expect(!s.nightModeActive(at: at(hour: 7), calendar: calendar), "the end hour is exclusive")
        #expect(!s.nightModeActive(at: at(hour: 15), calendar: calendar))
    }

    @Test("a schedule inside one day, and equal hours mean all day")
    func scheduleWithinADay() {
        let day = AudioShapingSettings(nightMode: .scheduled, nightStartHour: 13, nightEndHour: 15)
        #expect(day.nightModeActive(at: at(hour: 14), calendar: calendar))
        #expect(!day.nightModeActive(at: at(hour: 16), calendar: calendar))
        let allDay = AudioShapingSettings(nightMode: .scheduled, nightStartHour: 5, nightEndHour: 5)
        #expect(allDay.nightModeActive(at: at(hour: 9), calendar: calendar))
    }

    @Test("the values persist per device, and a stored hour out of range is clamped")
    func persistence() {
        let defaults = UserDefaults(suiteName: "AudioShapingSettingsTests-\(UUID().uuidString)")!
        let prefs = DevicePreferences(store: defaults)
        prefs.speakerLayout = .surround51
        prefs.dialogueBoost = .high
        prefs.nightMode = .scheduled
        prefs.nightModeStartHour = 21
        defaults.set(40, forKey: "playback.nightModeEndHour")
        let reread = DevicePreferences(store: defaults)
        #expect(reread.speakerLayout == .surround51)
        #expect(reread.dialogueBoost == .high)
        #expect(reread.nightMode == .scheduled)
        #expect(reread.nightModeStartHour == 21)
        #expect(reread.nightModeEndHour == 23)
    }
}
