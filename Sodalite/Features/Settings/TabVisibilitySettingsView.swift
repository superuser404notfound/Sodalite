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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
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
            }
            .screenContentInset()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .hidesShellTabBar()
        // Suppress the floating tvOS nav-title; the inline header below is the screen's own.
        .hidesNavigationBarChrome()
        .onAppear {
            if draft == nil { draft = appearance.hiddenTabs }
            if draftNavigationStyle == nil { draftNavigationStyle = appearance.navigationStyle }
        }
        .onDisappear(perform: commit)
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
        if let draftNavigationStyle, draftNavigationStyle != appearance.navigationStyle {
            appearance.navigationStyle = draftNavigationStyle
        }
        guard let draft else { return }
        appearance.setHiddenTabs(draft)
    }

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
        case .home, .settings: ""
        }
    }
}
