import Foundation

/// A player control the viewer can hide or move (Sodalite#194). Prompts (Skip Intro, Next Episode,
/// Return to Live) are not in here on purpose: they appear on their own and lead the row, so nobody
/// can hide them by accident.
enum PlayerControl: String, CaseIterable, Codable, Sendable {
    case restart, episodes, chapters, audio, subtitles, quality, speed, picture, pip, multiview, stats
    case rotationLock, childLock, airPlay
    case brightnessSwipe, volumeSwipe
}

/// One list in the configurator. `transport` is the tvOS VOD row and the touch icon row, which serves
/// live sessions too; `live` is the tvOS live row alone.
enum PlayerControlGroup: String, CaseIterable, Codable, Sendable {
    case transport, live, topBar, gestures

    /// The order the player shipped with before the configurator existed.
    var defaultControls: [PlayerControl] {
        switch self {
        case .transport: [.restart, .episodes, .chapters, .audio, .subtitles, .quality, .speed, .picture, .pip, .stats]
        case .live: [.audio, .subtitles, .pip, .multiview, .stats]
        case .topBar: [.rotationLock, .childLock, .airPlay]
        case .gestures: [.brightnessSwipe, .volumeSwipe]
        }
    }

    /// Two gestures on opposite screen edges have no order to arrange.
    var isReorderable: Bool { self != .gestures }
}

/// Which controls show, and in what order, per group. Hidden entries keep their place in `entries`,
/// so showing one again is an append at the end of the visible part, as on Customize Home.
struct PlayerControlsLayout: Equatable, Sendable {
    struct Entry: Equatable, Codable, Sendable {
        var control: PlayerControl
        var isVisible: Bool
    }

    private var groups: [PlayerControlGroup: [Entry]]

    /// Stats was a switch of its own before it joined the list, off by default; `showsStats` carries
    /// that switch over so nobody loses or gains the chip on update.
    static func defaults(showsStats: Bool = false) -> PlayerControlsLayout {
        var groups: [PlayerControlGroup: [Entry]] = [:]
        for group in PlayerControlGroup.allCases {
            groups[group] = group.defaultControls.map {
                Entry(control: $0, isVisible: $0 == .stats ? showsStats : true)
            }
        }
        return PlayerControlsLayout(groups: groups)
    }

    /// Visible entries in order, then hidden ones.
    func entries(in group: PlayerControlGroup) -> [Entry] {
        let all = groups[group] ?? []
        return all.filter(\.isVisible) + all.filter { !$0.isVisible }
    }

    func visibleControls(in group: PlayerControlGroup) -> [PlayerControl] {
        (groups[group] ?? []).filter(\.isVisible).map(\.control)
    }

    func isVisible(_ control: PlayerControl, in group: PlayerControlGroup) -> Bool {
        groups[group]?.first(where: { $0.control == control })?.isVisible ?? false
    }

    mutating func setVisible(_ visible: Bool, _ control: PlayerControl, in group: PlayerControlGroup) {
        var list = entries(in: group)
        guard let index = list.firstIndex(where: { $0.control == control }),
              list[index].isVisible != visible else { return }
        var entry = list.remove(at: index)
        entry.isVisible = visible
        // Shown again: last of the visible ones. Hidden: first of the hidden ones.
        let visibleCount = list.filter(\.isVisible).count
        list.insert(entry, at: visibleCount)
        groups[group] = list
    }

    /// Moves a visible control to `index` among the visible ones; hidden controls do not move.
    mutating func move(_ control: PlayerControl, toVisibleIndex index: Int, in group: PlayerControlGroup) {
        var visible = entries(in: group).filter(\.isVisible)
        guard let source = visible.firstIndex(where: { $0.control == control }) else { return }
        let entry = visible.remove(at: source)
        visible.insert(entry, at: min(max(index, 0), visible.count))
        groups[group] = visible + entries(in: group).filter { !$0.isVisible }
    }

    // MARK: - Storage

    /// Raw strings rather than `PlayerControl`, so a control a newer build added (and synced here)
    /// drops out instead of failing the whole layout.
    private struct StoredEntry: Codable {
        var control: String
        var visible: Bool
    }

    func encoded() -> String {
        var raw: [String: [StoredEntry]] = [:]
        for (group, list) in groups {
            raw[group.rawValue] = list.map { StoredEntry(control: $0.control.rawValue, visible: $0.isVisible) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(raw) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lossy on purpose: unknown groups and controls are skipped, a duplicate keeps its first place,
    /// and a control missing from a stored group (one a later build added) is appended with its
    /// default visibility.
    static func decoded(_ string: String, showsStats: Bool = false) -> PlayerControlsLayout {
        let fallback = defaults(showsStats: showsStats)
        guard let raw = try? JSONDecoder().decode([String: [StoredEntry]].self, from: Data(string.utf8)) else {
            return fallback
        }
        var groups: [PlayerControlGroup: [Entry]] = [:]
        for group in PlayerControlGroup.allCases {
            guard let stored = raw[group.rawValue] else {
                groups[group] = fallback.groups[group]
                continue
            }
            let allowed = Set(group.defaultControls)
            var list: [Entry] = []
            for item in stored {
                guard let control = PlayerControl(rawValue: item.control), allowed.contains(control),
                      !list.contains(where: { $0.control == control }) else { continue }
                list.append(Entry(control: control, isVisible: item.visible))
            }
            for entry in fallback.groups[group] ?? [] where !list.contains(where: { $0.control == entry.control }) {
                list.append(entry)
            }
            groups[group] = list
        }
        return PlayerControlsLayout(groups: groups)
    }
}
