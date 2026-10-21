import SwiftUI

/// Sodalite#194: which player controls show, and in what order. Built like Customize Home: a click on
/// a control picks it up and a click on another drops it there, the switch beside it shows or hides it,
/// and hidden controls sink below the divider. Each platform lists only the controls it has.
struct PlayerControlsSettingsView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var moving: Moving?

    private struct Moving: Equatable {
        let group: PlayerControlGroup
        let control: PlayerControl
    }

    private var prefs: PlaybackPreferences { dependencies.playbackPreferences }

    private var hInset: CGFloat { hSizeClass == .compact ? 16 : 50 }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                ForEach(Self.groups, id: \.self) { group in
                    groupSection(group)
                }
                Text("playerControls.prompts")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, hInset)
            }
            .padding(.vertical, 40)
        }
        .hidesNavigationBarChrome()
        .hidesShellTabBar()
    }

    // MARK: - Platform

    #if os(tvOS)
    private static let groups: [PlayerControlGroup] = [.transport, .live]
    #else
    private static let groups: [PlayerControlGroup] = [.transport, .topBar, .gestures]
    #endif

    /// Controls this device's player can draw at all.
    private static func isOffered(_ control: PlayerControl) -> Bool {
        switch control {
        #if os(tvOS)
        case .pip, .multiview: return true
        #else
        case .pip, .multiview: return false
        #endif
        #if os(iOS)
        case .rotationLock: return PlayerOrientation.isPhone
        #endif
        default: return true
        }
    }

    private static func title(for group: PlayerControlGroup) -> LocalizedStringKey {
        switch group {
        #if os(tvOS)
        case .transport: "playerControls.section.transport"
        #else
        case .transport: "playerControls.section.controls"
        #endif
        case .live: "tab.liveTV"
        case .topBar: "playerControls.section.topBar"
        case .gestures: "playerControls.section.gestures"
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.playerControls.title")
                    .font(.title3)
                    .fontWeight(.semibold)

                SettingsScopeCaption()

                Text(moving != nil ? "home.customize.moveTip" : "playerControls.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            FocusableTile(action: {
                moving = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    // Stats starts from where it is now: Restore Defaults is about order and the
                    // shipped set, and the chip was never in that set.
                    let stats = prefs.showStatsForNerds
                    prefs.playerControls = .defaults(showsStats: stats)
                }
            }) { isFocused in
                Label("home.customize.resetDefaults", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(isFocused ? Color.Theme.focusFill : Color.Theme.restFill)
                    )
            }
        }
        .padding(.horizontal, hInset)
    }

    // MARK: - Groups

    private func groupSection(_ group: PlayerControlGroup) -> some View {
        let entries = prefs.playerControls.entries(in: group).filter { Self.isOffered($0.control) }
        let visible = entries.filter(\.isVisible)
        let hidden = entries.filter { !$0.isVisible }
        return VStack(spacing: 6) {
            Text(Self.title(for: group))
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, hInset)
                .padding(.bottom, 4)

            ForEach(visible, id: \.control) { entry in
                controlRow(entry.control, in: group, isVisible: true)
                diagnosticsRowIfNeeded(below: entry.control, in: group)
            }

            if !hidden.isEmpty {
                inactiveDivider
                ForEach(hidden, id: \.control) { entry in
                    controlRow(entry.control, in: group, isVisible: false)
                }
            }
        }
    }

    /// Engine Diagnostics adds counters to the Stats panel, so it sits under the first visible Stats
    /// entry and leaves with it. It stays a device value, as it was on the Playback screen.
    @ViewBuilder
    private func diagnosticsRowIfNeeded(below control: PlayerControl, in group: PlayerControlGroup) -> some View {
        if control == .stats,
           Self.groups.first(where: { prefs.playerControls.isVisible(.stats, in: $0) }) == group {
            ValuePickerRow(
                icon: "waveform.path.ecg",
                title: "settings.playback.engineDiagnostics.title",
                subtitle: "settings.playback.engineDiagnostics.subtitle",
                options: [false, true],
                selection: Binding(
                    get: { prefs.showEngineDiagnostics },
                    set: { prefs.showEngineDiagnostics = $0 }
                ),
                label: { on in
                    on
                        ? String(localized: "settings.playback.on", defaultValue: "On")
                        : String(localized: "settings.playback.off", defaultValue: "Off")
                }
            )
            .settingsValueScope(.device)
            .padding(.horizontal, hInset)
        }
    }

    private var inactiveDivider: some View {
        HStack(spacing: 12) {
            Text("home.customize.inactive")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.Theme.restFillStrong)
                .frame(height: 1)
        }
        .padding(.horizontal, hInset)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    // MARK: - Row

    /// Two focus targets per row, as on Customize Home: the body moves (or, hidden, shows) the control,
    /// the switch shows or hides it. A gesture has no order, so its body toggles too.
    private func controlRow(_ control: PlayerControl, in group: PlayerControlGroup, isVisible: Bool) -> some View {
        let isMoving = moving == Moving(group: group, control: control)
        return HStack(spacing: 16) {
            FocusableTile(isHighlighted: isMoving, action: {
                if isVisible && group.isReorderable {
                    handleTap(control, in: group)
                } else {
                    toggle(control, in: group)
                }
            }) { isFocused in
                tile(control, isFocused: isFocused, isMoving: isMoving, isVisible: isVisible)
            }

            RowToggleButton(isOn: isVisible) {
                toggle(control, in: group)
            }
        }
        .padding(.horizontal, hInset)
    }

    private func tile(_ control: PlayerControl, isFocused: Bool, isMoving: Bool, isVisible: Bool) -> some View {
        HStack(spacing: 20) {
            Image(systemName: Self.symbol(for: control))
                .font(.title3)
                .frame(width: 44)
                .foregroundStyle(isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

            Text(Self.label(for: control))
                .font(.body)
                .foregroundStyle(isVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            Spacer()

            if isMoving {
                Text("home.customize.moving")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(background(isFocused: isFocused, isMoving: isMoving, isVisible: isVisible))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isMoving ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(Color.clear), lineWidth: 2)
        )
        .focusStroke(cornerRadius: 12, isFocused: isFocused)
    }

    private func background(isFocused: Bool, isMoving: Bool, isVisible: Bool) -> AnyShapeStyle {
        if isMoving { return AnyShapeStyle(TintShapeStyle.tint.opacity(0.12)) }
        if isFocused { return AnyShapeStyle(Color.Theme.focusFill) }
        return AnyShapeStyle(isVisible ? Color.Theme.restFill : Color.Theme.restFillFaint)
    }

    // MARK: - Actions

    private func handleTap(_ control: PlayerControl, in group: PlayerControlGroup) {
        guard let picked = moving, picked.group == group else {
            withAnimation(.easeInOut(duration: 0.2)) { moving = Moving(group: group, control: control) }
            return
        }
        if picked.control != control,
           let target = prefs.playerControls.visibleControls(in: group).firstIndex(of: control) {
            withAnimation(.easeInOut(duration: 0.25)) {
                prefs.playerControls.move(picked.control, toVisibleIndex: target, in: group)
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) { moving = nil }
    }

    private func toggle(_ control: PlayerControl, in group: PlayerControlGroup) {
        moving = nil
        let visible = prefs.playerControls.isVisible(control, in: group)
        withAnimation(.easeInOut(duration: 0.25)) {
            prefs.playerControls.setVisible(!visible, control, in: group)
        }
    }

    // MARK: - Labels

    static func label(for control: PlayerControl) -> String {
        switch control {
        case .restart: String(localized: "player.restart", defaultValue: "Restart")
        case .episodes: String(localized: "player.episodes", defaultValue: "Episodes")
        case .chapters: String(localized: "player.chapters", defaultValue: "Chapters")
        case .audio: String(localized: "player.audio", defaultValue: "Audio")
        case .subtitles: String(localized: "player.subtitles", defaultValue: "Subtitles")
        case .quality: String(localized: "settings.playback.quality", defaultValue: "Streaming Quality")
        case .speed: String(localized: "playerControls.control.speed", defaultValue: "Playback Speed")
        case .picture: String(localized: "playerControls.control.picture", defaultValue: "Picture Mode")
        case .pip: String(localized: "player.pip", defaultValue: "Picture in Picture")
        case .multiview: String(localized: "multiview.button", defaultValue: "Multiview")
        case .stats: String(localized: "player.stats.title", defaultValue: "Stats for Nerds")
        case .rotationLock: String(localized: "playerControls.control.rotationLock", defaultValue: "Rotation Lock")
        case .childLock: String(localized: "player.lock.engage", defaultValue: "Lock controls")
        case .airPlay: String(localized: "playerControls.control.airPlay", defaultValue: "AirPlay")
        case .brightnessSwipe: String(localized: "playerControls.control.brightnessSwipe", defaultValue: "Brightness (swipe on the left edge)")
        case .volumeSwipe: String(localized: "playerControls.control.volumeSwipe", defaultValue: "Volume (swipe on the right edge)")
        }
    }

    /// The glyph the player itself draws for the control, so the list reads like the bar.
    static func symbol(for control: PlayerControl) -> String {
        switch control {
        case .restart: "arrow.counterclockwise"
        case .episodes: "list.bullet"
        case .chapters: "rectangle.split.3x1"
        case .audio: "speaker.wave.2"
        case .subtitles: "captions.bubble"
        case .quality: "dial.medium"
        case .speed: "gauge.with.needle"
        case .picture: "rectangle.ratio.16.to.9"
        case .pip: "pip.enter"
        case .multiview: "rectangle.split.2x2"
        case .stats: "info.circle"
        case .rotationLock: "lock.rotation"
        case .childLock: "lock.fill"
        case .airPlay: "airplayvideo"
        case .brightnessSwipe: "sun.max.fill"
        case .volumeSwipe: "speaker.wave.2.fill"
        }
    }
}
