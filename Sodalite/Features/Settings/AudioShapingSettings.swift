import Foundation
import AetherEngine

/// AetherEngine#923: the three audio shaping settings, as the viewer picks them. Device values: they
/// describe the room and the speakers behind this box, so every profile on it shares them.

/// How many channels the box sends at most. Auto leaves the route to decide.
enum SpeakerLayout: String, CaseIterable, Sendable, Identifiable {
    case auto, stereo, surround51
    var id: String { rawValue }
    var titleKey: String { "settings.playback.speakers.\(rawValue)" }
    var maxChannels: Int? {
        switch self {
        case .auto:       return nil
        case .stereo:     return 2
        case .surround51: return 6
        }
    }
}

/// How far the dialogue is lifted against the rest of the mix.
enum DialogueBoost: String, CaseIterable, Sendable, Identifiable {
    case off, low, medium, high
    var id: String { rawValue }
    var titleKey: String { "settings.playback.dialogueBoost.\(rawValue)" }
    var gainDB: Double {
        switch self {
        case .off:    return 0
        case .low:    return 3
        case .medium: return 6
        case .high:   return 9
        }
    }
}

/// Dynamic-range compression: off, always on, or on between two hours of the day.
enum NightMode: String, CaseIterable, Sendable, Identifiable {
    case off, on, scheduled
    var id: String { rawValue }
    var titleKey: String { "settings.playback.nightMode.\(rawValue)" }
}

/// Everything the engine needs, resolved against the clock.
struct AudioShapingSettings: Equatable, Sendable {
    var speakers: SpeakerLayout = .auto
    var dialogue: DialogueBoost = .off
    var nightMode: NightMode = .off
    /// Hours of the day, 0...23. A start after the end runs across midnight (22 to 7).
    var nightStartHour: Int = 22
    var nightEndHour: Int = 7

    /// Whether night mode is in force at `date`. Start inclusive, end exclusive; equal hours mean the
    /// whole day, which is what someone who set both to the same hour most likely meant.
    func nightModeActive(at date: Date, calendar: Calendar = .current) -> Bool {
        switch nightMode {
        case .off: return false
        case .on: return true
        case .scheduled:
            let hour = calendar.component(.hour, from: date)
            if nightStartHour == nightEndHour { return true }
            if nightStartHour < nightEndHour { return hour >= nightStartHour && hour < nightEndHour }
            return hour >= nightStartHour || hour < nightEndHour
        }
    }

    func shaping(at date: Date, calendar: Calendar = .current) -> AudioShaping {
        AudioShaping(maxChannels: speakers.maxChannels,
                     dialogueGainDB: dialogue.gainDB,
                     compressor: nightModeActive(at: date, calendar: calendar) ? .night : nil)
    }

    /// "22:00" in the viewer's locale, for the schedule rows.
    static func hourLabel(_ hour: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
