import SwiftUI

/// Sodalite#62: pick which tabs the navigation bar shows, Sodalite#235: and in what order, and on tvOS
/// (Sodalite#140) whether that bar is the one across the top or the collapsing sidebar.
///
/// Built like Player Controls: one list of the app's optional tabs and the libraries that can be
/// pinned as tabs. A click on a shown tab picks it up and a click on another drops it there, the
/// switch beside it shows or hides it, and hidden ones sink below the divider. Home and Settings are
/// not listed, they are the landing tab and the only route back to this screen, so they keep the two
/// ends of the bar. Live TV and Music stay listed even when the active server offers neither: rows
/// appearing under the focused one is a tvOS focus hazard, and their subtitles say the server has the
/// last word.
struct TabVisibilitySettingsView: View {
    @Environment(\.dependencies) private var dependencies

    private var appearance: AppearancePreferences { dependencies.appearancePreferences }

    /// Edits are collected here and written on the way out. Writing them live changes the tab set
    /// under this screen, and rebuilding the TabView's tab list drops the navigation stack of the
    /// Settings tab, which threw the user back to the settings root on every single toggle.
    @State private var draft: Set<AppTab>?

    /// Sodalite#235. Held back for the same reason: a new order rebuilds the bar.
    @State private var draftOrder: [String]?

    /// The tab picked up for a move, by its `TabOrder` key.
    @State private var moving: String?

    /// Sodalite#140. Held back for the same reason: switching the style rebuilds the whole TabView,
    /// which takes this screen's navigation stack with it and drops the viewer back on Home mid-edit.
    @State private var draftNavigationStyle: AppearancePreferences.NavigationStyle?

    /// The profile the drafts were read from. `appearance` resolves the ACTIVE profile when it is
    /// written, so a commit after a profile switch would hand these drafts to the next profile.
    @State private var draftProfile: ProfileKey?

    #if os(tvOS) || os(iOS)
    @Environment(\.appState) private var appState
    /// The profile's browsable libraries in its My Media order, nil until they arrive.
    @State private var libraries: [JellyfinLibrary]?
    /// False when a combined secondary did not answer, so its pins are kept rather than dropped.
    @State private var librariesComplete = false
    /// Held back like the tab set: a pin changes the bar, which rebuilds the Settings stack.
    @State private var draftPins: Set<String>?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                SettingsScopeCaption()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                #if os(tvOS)
                sectionHeader("settings.tabs.section.navigation")

                ValuePickerRow(
                    icon: "sidebar.leading",
                    title: "settings.tabs.navigation.title",
                    subtitle: "settings.tabs.navigation.subtitle",
                    options: AppearancePreferences.NavigationStyle.allCases,
                    selection: navigationStyleBinding,
                    label: \.title
                )
                .padding(.bottom, 8)
                #endif

                tabsHeader

                Text(moving != nil ? "home.customize.moveTip" : "settings.tabs.order.description")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                tabList

                Text("settings.tabs.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            .screenContentInset()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .hidesShellTabBar()
        // Suppress the floating tvOS nav-title; the inline header below is the screen's own.
        .hidesNavigationBarChrome()
        .onAppear {
            if draftProfile != dependencies.activeProfileKey {
                draftProfile = dependencies.activeProfileKey
                draft = nil
                draftOrder = nil
                draftNavigationStyle = nil
                moving = nil
                #if os(tvOS) || os(iOS)
                draftPins = nil
                libraries = nil
                #endif
            }
            if draft == nil { draft = appearance.hiddenTabs }
            if draftOrder == nil { draftOrder = appearance.tabOrder }
            if draftNavigationStyle == nil { draftNavigationStyle = appearance.navigationStyle }
        }
        .onDisappear(perform: commit)
        #if os(tvOS) || os(iOS)
        .task(id: draftProfile) {
            guard ShellTab.supportsLibraryTabs else { return }
            await loadLibraries()
        }
        #endif
    }

    // MARK: - Model

    private var editedTabs: Set<AppTab> { draft ?? appearance.hiddenTabs }

    private var editedOrder: [String] { draftOrder ?? appearance.tabOrder }

    /// The shown tabs in bar order, then the hidden ones. Shown pins come first in the default
    /// arrangement, as they do in the bar, so both arrange the same list the same way.
    private var arrangedTabs: (shown: [ShellTab], hidden: [ShellTab]) {
        let apps = AppTab.hideableCases
        let pins = libraryCandidates.map(ShellTab.library)
        let shown = pins.filter(isShown) + apps.map(ShellTab.app).filter(isShown)
        let hidden = apps.map(ShellTab.app).filter { !isShown($0) } + pins.filter { !isShown($0) }
        return (TabOrder.arrange(shown, by: editedOrder), hidden)
    }

    /// Every library that can be pinned, in My Media order once the list is in. Until then, and for
    /// a pin whose server did not answer, the stored pins stand in, so the shown part of the list is
    /// complete on the first frame.
    private var libraryCandidates: [PinnedLibraryTab] {
        #if os(tvOS) || os(iOS)
        guard ShellTab.supportsLibraryTabs else { return [] }
        let listed = (libraries ?? []).map(PinnedLibraryTab.init(library:))
        let listedKeys = Set(listed.map(\.originKey))
        let keepsUnlisted = libraries == nil || !librariesComplete
        let unlisted = keepsUnlisted
            ? appearance.pinnedLibraryTabs.filter { !listedKeys.contains($0.originKey) }
            : []
        return listed + unlisted
        #else
        return []
        #endif
    }

    private func isShown(_ tab: ShellTab) -> Bool {
        switch tab {
        case .app(let app):
            return !editedTabs.contains(app)
        case .library(let pin):
            #if os(tvOS) || os(iOS)
            return editedPins.contains(pin.originKey)
            #else
            _ = pin
            return false
            #endif
        }
    }

    // MARK: - Actions

    private func handleTap(_ tab: ShellTab) {
        guard let key = TabOrder.key(for: tab) else { return }
        guard let picked = moving else {
            withAnimation(.easeInOut(duration: 0.2)) { moving = key }
            return
        }
        let shown = arrangedTabs.shown
        if picked != key,
           let source = shown.firstIndex(where: { TabOrder.key(for: $0) == picked }),
           let target = shown.firstIndex(of: tab) {
            var next = shown
            next.insert(next.remove(at: source), at: target)
            withAnimation(.easeInOut(duration: 0.25)) {
                draftOrder = next.compactMap(TabOrder.key(for:))
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) { moving = nil }
    }

    /// A tab shown again lands last among the shown ones, the way Player Controls does it. Without
    /// an order of its own the list stays on the default one, so a toggle alone never freezes it.
    private func toggle(_ tab: ShellTab) {
        moving = nil
        let show = !isShown(tab)
        withAnimation(.easeInOut(duration: 0.25)) {
            if !editedOrder.isEmpty, let key = TabOrder.key(for: tab) {
                let shownKeys = arrangedTabs.shown.compactMap(TabOrder.key(for:)).filter { $0 != key }
                draftOrder = show ? shownKeys + [key] : shownKeys
            }
            switch tab {
            case .app(let app):
                var next = editedTabs
                if show { next.remove(app) } else { next.insert(app) }
                draft = next
            case .library(let pin):
                #if os(tvOS) || os(iOS)
                var next = editedPins
                if show { next.insert(pin.originKey) } else { next.remove(pin.originKey) }
                draftPins = next
                #else
                _ = pin
                #endif
            }
        }
    }

    private func restoreDefaultOrder() {
        moving = nil
        withAnimation(.easeInOut(duration: 0.25)) { draftOrder = [] }
    }

    private func commit() {
        guard draftProfile == dependencies.activeProfileKey else { return }
        moving = nil
        if let draftNavigationStyle, draftNavigationStyle != appearance.navigationStyle {
            appearance.navigationStyle = draftNavigationStyle
        }
        #if os(tvOS) || os(iOS)
        commitPins()
        #endif
        if let draftOrder { appearance.setTabOrder(draftOrder) }
        guard let draft else { return }
        appearance.setHiddenTabs(draft)
    }

    #if os(tvOS) || os(iOS)
    private var editedPins: Set<String> {
        draftPins ?? Set(appearance.pinnedLibraryTabs.map(\.originKey))
    }

    private func loadLibraries() async {
        guard let userID = appState.activeUser?.id, let scope = draftProfile else { return }
        let sources = dependencies.homeSources(activeUserID: userID)
        guard let result = await CustomizeLibraryList.fetch(sources, secondaryDeadline: .seconds(4)),
              scope == draftProfile
        else { return }
        let activeServerID = appState.activeServer?.id ?? ""
        libraries = LibraryLayout.load(scope: scope.storageScope)
            .ordered(MyMediaLibraries.browsable(result.libraries), fallbackServerID: activeServerID)
        librariesComplete = result.complete
    }

    /// Pins in My Media order, with the names the server has now; their place in the bar is the tab
    /// order's business. A pin whose library is not in the list is kept only while the list is
    /// incomplete: a secondary may just not have answered.
    private func commitPins() {
        guard let libraries else { return }
        let pinned = editedPins
        let listed = Set(libraries.map(\.originKey))
        var pins = libraries.filter { pinned.contains($0.originKey) }.map(PinnedLibraryTab.init(library:))
        if !librariesComplete {
            pins += appearance.pinnedLibraryTabs.filter { pinned.contains($0.originKey) && !listed.contains($0.originKey) }
        }
        appearance.setPinnedLibraryTabs(pins)
    }
    #endif

    private var navigationStyleBinding: Binding<AppearancePreferences.NavigationStyle> {
        Binding(
            get: { draftNavigationStyle ?? appearance.navigationStyle },
            set: { draftNavigationStyle = $0 }
        )
    }

    // MARK: - Views

    private var header: some View {
        Text("settings.tabs.title")
            .font(.largeTitle)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 4)
    }

    /// The section title with the way back to the default order. Always there rather than only
    /// while an order is set: a button vanishing under the focus that just clicked it leaves the
    /// focus to the engine's guess.
    private var tabsHeader: some View {
        HStack(alignment: .bottom) {
            sectionHeader("settings.tabs.section.visibility")
            Spacer()
            FocusableTile(action: restoreDefaultOrder) { isFocused in
                Label("home.customize.resetDefaults", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(isFocused ? Color.Theme.focusFill : Color.Theme.restFill)
                    )
            }
            .padding(.bottom, 4)
        }
    }

    private var tabList: some View {
        let lists = arrangedTabs
        return VStack(spacing: 6) {
            ForEach(lists.shown, id: \.self) { tab in
                tabRow(tab, isShown: true)
            }
            if !lists.hidden.isEmpty {
                inactiveDivider
                // Last, because the libraries arrive from the server: rows appearing under the
                // focused one would move it.
                ForEach(lists.hidden, id: \.self) { tab in
                    tabRow(tab, isShown: false)
                }
            }
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
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    /// Two focus targets per row, as on Customize Home: the body moves a shown tab (or shows a
    /// hidden one), the switch shows or hides it.
    private func tabRow(_ tab: ShellTab, isShown: Bool) -> some View {
        let isMoving = moving != nil && moving == TabOrder.key(for: tab)
        return HStack(spacing: 16) {
            FocusableTile(isHighlighted: isMoving, action: {
                if isShown {
                    handleTap(tab)
                } else {
                    toggle(tab)
                }
            }) { isFocused in
                tile(tab, isFocused: isFocused, isMoving: isMoving, isShown: isShown)
            }

            RowToggleButton(isOn: isShown) {
                toggle(tab)
            }
        }
    }

    private func tile(_ tab: ShellTab, isFocused: Bool, isMoving: Bool, isShown: Bool) -> some View {
        HStack(spacing: 20) {
            Image(systemName: tab.systemImage)
                .font(.title3)
                .frame(width: 44)
                .foregroundStyle(isShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 4) {
                tab.title
                    .font(.body)
                    .foregroundStyle(isShown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(subtitleKey(for: tab))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                .fill(background(isFocused: isFocused, isMoving: isMoving, isShown: isShown))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isMoving ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(Color.clear), lineWidth: 2)
        )
        .focusStroke(cornerRadius: 12, isFocused: isFocused)
    }

    private func background(isFocused: Bool, isMoving: Bool, isShown: Bool) -> AnyShapeStyle {
        if isMoving { return AnyShapeStyle(TintShapeStyle.tint.opacity(0.12)) }
        if isFocused { return AnyShapeStyle(Color.Theme.focusFill) }
        return AnyShapeStyle(isShown ? Color.Theme.restFill : Color.Theme.restFillFaint)
    }

    private func subtitleKey(for tab: ShellTab) -> LocalizedStringKey {
        switch tab {
        case .library: "settings.tabs.library.opensGrid"
        case .app(let app):
            switch app {
            case .liveTV: "settings.tabs.liveTV.subtitle"
            case .catalog: "settings.tabs.catalog.subtitle"
            case .search: "settings.tabs.search.subtitle"
            case .music: "settings.tabs.music.subtitle"
            case .downloads: "settings.tabs.downloads.subtitle"
            case .home, .settings, .profiles: ""
            }
        }
    }
}
