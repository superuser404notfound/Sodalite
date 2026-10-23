import SwiftUI

/// Sodalite#62: pick which tabs the navigation bar shows, and on tvOS (Sodalite#140) whether that
/// bar is the one across the top or the collapsing sidebar. Home and Settings are not listed, they are
/// the landing tab and the only route back to this screen. Live TV and Music stay listed even when
/// the active server offers neither: rows appearing under the focused one is a tvOS focus hazard,
/// and their subtitles say the server has the last word.
struct TabVisibilitySettingsView: View {
    @Environment(\.dependencies) private var dependencies

    private var appearance: AppearancePreferences { dependencies.appearancePreferences }

    /// Edits are collected here and written on the way out. Writing them live changes the tab set
    /// under this screen, and rebuilding the TabView's tab list drops the navigation stack of the
    /// Settings tab, which threw the user back to the settings root on every single toggle.
    @State private var draft: Set<AppTab>?

    /// Sodalite#140. Held back for the same reason: switching the style rebuilds the whole TabView,
    /// which takes this screen's navigation stack with it and drops the viewer back on Home mid-edit.
    @State private var draftNavigationStyle: AppearancePreferences.NavigationStyle?

    /// The profile the drafts were read from. `appearance` resolves the ACTIVE profile when it is
    /// written, so a commit after a profile switch would hand these drafts to the next profile.
    @State private var draftProfile: ProfileKey?

    #if os(tvOS)
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

                sectionHeader("settings.tabs.section.visibility")
                #endif

                Text("settings.tabs.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                ForEach(AppTab.hideableCases, id: \.self) { tab in
                    ValuePickerRow(
                        icon: tab.systemImage,
                        title: tab.labelKey,
                        subtitle: subtitleKey(for: tab),
                        options: [false, true],
                        selection: visibilityBinding(for: tab),
                        label: { visible in
                            visible
                                ? String(localized: "settings.playback.on", defaultValue: "On")
                                : String(localized: "settings.playback.off", defaultValue: "Off")
                        }
                    )
                }

                Text("settings.tabs.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)

                #if os(tvOS)
                // Last, because the list arrives from the server: rows appearing under the focused
                // one would move it.
                if let libraries, !libraries.isEmpty {
                    sectionHeader("settings.tabs.section.libraries")
                    Text("settings.tabs.libraries.caption")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 16)
                    ForEach(libraries, id: \.originKey) { library in
                        ValuePickerRow(
                            icon: PinnedLibraryTab(library: library).systemImage,
                            title: LocalizedStringKey(library.name),
                            subtitle: "settings.tabs.library.subtitle",
                            options: [false, true],
                            selection: pinBinding(for: library),
                            label: { pinned in
                                pinned
                                    ? String(localized: "settings.playback.on", defaultValue: "On")
                                    : String(localized: "settings.playback.off", defaultValue: "Off")
                            }
                        )
                    }
                }
                #endif
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
                draftNavigationStyle = nil
                #if os(tvOS)
                draftPins = nil
                libraries = nil
                #endif
            }
            if draft == nil { draft = appearance.hiddenTabs }
            if draftNavigationStyle == nil { draftNavigationStyle = appearance.navigationStyle }
        }
        .onDisappear(perform: commit)
        #if os(tvOS)
        .task(id: draftProfile) { await loadLibraries() }
        #endif
    }

    private var editedTabs: Set<AppTab> { draft ?? appearance.hiddenTabs }

    private var navigationStyleBinding: Binding<AppearancePreferences.NavigationStyle> {
        Binding(
            get: { draftNavigationStyle ?? appearance.navigationStyle },
            set: { draftNavigationStyle = $0 }
        )
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 4)
    }

    private func visibilityBinding(for tab: AppTab) -> Binding<Bool> {
        Binding(
            get: { !editedTabs.contains(tab) },
            set: { visible in
                var next = editedTabs
                if visible {
                    next.remove(tab)
                } else {
                    next.insert(tab)
                }
                draft = next
            }
        )
    }

    private func commit() {
        guard draftProfile == dependencies.activeProfileKey else { return }
        if let draftNavigationStyle, draftNavigationStyle != appearance.navigationStyle {
            appearance.navigationStyle = draftNavigationStyle
        }
        #if os(tvOS)
        commitPins()
        #endif
        guard let draft else { return }
        appearance.setHiddenTabs(draft)
    }

    #if os(tvOS)
    private var editedPins: Set<String> {
        draftPins ?? Set(appearance.pinnedLibraryTabs.map(\.originKey))
    }

    private func pinBinding(for library: JellyfinLibrary) -> Binding<Bool> {
        Binding(
            get: { editedPins.contains(library.originKey) },
            set: { pinned in
                var next = editedPins
                if pinned {
                    next.insert(library.originKey)
                } else {
                    next.remove(library.originKey)
                }
                draftPins = next
            }
        )
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

    /// Pins in My Media order, with the names the server has now. A pin whose library is not in
    /// the list is kept only while the list is incomplete: a secondary may just not have answered.
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

    private var header: some View {
        Text("settings.tabs.title")
            .font(.largeTitle)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
    }

    private func subtitleKey(for tab: AppTab) -> LocalizedStringKey {
        switch tab {
        case .liveTV: "settings.tabs.liveTV.subtitle"
        case .catalog: "settings.tabs.catalog.subtitle"
        case .search: "settings.tabs.search.subtitle"
        case .music: "settings.tabs.music.subtitle"
        case .downloads: "settings.tabs.downloads.subtitle"
        case .home, .settings, .profiles: ""
        }
    }
}
