import Foundation
import AetherEngine

/// One row of the in-player audio menu: a track, or one of the three shaping settings
/// (AetherEngine#923) stepped with left/right like the subtitle timing row.
enum AudioMenuRow: Equatable {
    case track(id: Int)
    case speakers
    case dialogue
    case nightMode
}

extension PlayerViewModel {

    /// Row order of the in-player audio menu, read by both transport bars, the iOS panel, the
    /// highlight navigation and the Select commit.
    var audioMenuRows: [AudioMenuRow] {
        var rows = displayAudioTracks.map { AudioMenuRow.track(id: $0.id) }
        if supportsAudioShaping { rows += [.speakers, .dialogue, .nightMode] }
        return rows
    }

    /// AVPlayer owns the audio of a server transcode (the remote-HLS route), so there is no PCM for
    /// the engine to shape and the rows would do nothing.
    var supportsAudioShaping: Bool {
        player.videoRoute != .remoteBypass && !displayAudioTracks.isEmpty
    }

    func audioMenuLabel(for row: AudioMenuRow) -> String {
        func value(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
        switch row {
        case .track(let id):
            return displayAudioTracks.first(where: { $0.id == id }).map(TrackDisplayFormatter.audioDisplayName(for:)) ?? ""
        case .speakers:
            return String(format: String(localized: "player.audio.speakers.value", defaultValue: "Speakers: %@"),
                          value(preferences.speakerLayout.titleKey))
        case .dialogue:
            return String(format: String(localized: "player.audio.dialogue.value", defaultValue: "Dialogue boost: %@"),
                          value(preferences.dialogueBoost.titleKey))
        case .nightMode:
            var label = value(preferences.nightMode.titleKey)
            if preferences.nightMode == .scheduled {
                let active = preferences.device.audioShapingSettings.nightModeActive(at: Date())
                label += " (" + String(localized: active ? "player.audio.nightMode.activeNow" : "player.audio.nightMode.inactiveNow") + ")"
            }
            return String(format: String(localized: "player.audio.nightMode.value", defaultValue: "Night mode: %@"), label)
        }
    }

    /// Left/right on a setting row. Clamped at both ends, the way the subtitle timing row is.
    func stepAudioSetting(_ row: AudioMenuRow, by steps: Int) {
        func stepped<T: CaseIterable & Equatable>(_ value: T) -> T where T.AllCases == [T] {
            let all = T.allCases
            let index = all.firstIndex(of: value) ?? 0
            return all[max(0, min(all.count - 1, index + steps))]
        }
        switch row {
        case .track: return
        case .speakers: preferences.speakerLayout = stepped(preferences.speakerLayout)
        case .dialogue: preferences.dialogueBoost = stepped(preferences.dialogueBoost)
        case .nightMode: preferences.nightMode = stepped(preferences.nightMode)
        }
        applyAudioShaping()
    }

    /// Select on a setting row: the next value, wrapping, so a remote without left/right in the menu
    /// (and a tap on iOS) still reaches every value.
    func cycleAudioSetting(_ row: AudioMenuRow) {
        func next<T: CaseIterable & Equatable>(_ value: T) -> T where T.AllCases == [T] {
            let all = T.allCases
            return all[((all.firstIndex(of: value) ?? 0) + 1) % all.count]
        }
        switch row {
        case .track: return
        case .speakers: preferences.speakerLayout = next(preferences.speakerLayout)
        case .dialogue: preferences.dialogueBoost = next(preferences.dialogueBoost)
        case .nightMode: preferences.nightMode = next(preferences.nightMode)
        }
        applyAudioShaping()
    }

    /// Hands the engine what the settings resolve to now. A no-op when that is already in force, so
    /// the schedule check can call it on every tick: only a real change costs the engine a rebuild.
    func applyAudioShaping(at date: Date = Date()) {
        guard !isTearingDown else { return }
        let next = preferences.audioShaping(at: date).clamped
        guard next != player.audioShaping else { return }
        LogTap.shared.note("[Audio] shaping \(next.summary) (was \(player.audioShaping.summary))")
        player.setAudioShaping(next)
    }
}

#if !os(macOS)
extension PlayerViewModel {
    /// The audio menu as dropdown rows, shared by the VOD and the live transport bar. The setting rows
    /// are pinned under the track list, the first behind a separator.
    func audioDropdownItems(highlighted: Int) -> [DropdownItem] {
        audioMenuRows.enumerated().map { index, row in
            let isHighlighted = index == highlighted
            switch row {
            case .track(let id):
                return DropdownItem(title: audioMenuLabel(for: row), isActive: id == activeAudioIndex,
                                    isHighlighted: isHighlighted)
            case .speakers, .dialogue, .nightMode:
                return DropdownItem(title: audioMenuLabel(for: row), isActive: false,
                                    isHighlighted: isHighlighted,
                                    hint: isHighlighted ? "\u{2039} \u{203A}" : nil,
                                    isPinnedFooter: true,
                                    separatorAbove: row == .speakers)
            }
        }
    }
}
#endif
