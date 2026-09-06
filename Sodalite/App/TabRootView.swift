import SwiftUI
import UIKit

struct TabRootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var availableTabs: [AppTab] = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
    /// Last requestContentReload this view answered, so a reappear does not re-probe a signal it
    /// already handled.
    @State private var lastHandledContentReload = 0

    /// serverDidSwitch value of the last completed tab probe. -1 so the first probe fires; a `.task` re-fire on reappear is a no-op while a real switch re-probes.
    @State private var lastProbedServerSwitch = -1
    /// Re-probe triggered by .loginDidComplete (add-server / add-profile authenticates via setAuthenticated WITHOUT bumping serverDidSwitch, so the serverDidSwitch probe never fires for the new server).
    @State private var loginProbeTask: Task<Void, Never>?
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState
    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false

    private var iconColor: Color {
        appearanceTheme.palette.navigation.color
    }

    private var appearance: AppearancePreferences {
        dependencies.appearancePreferences
    }

    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        Label {
            Text(tab.labelKey)
        } icon: {
            // .monochrome strips the baked white that "tv" renders hierarchically, which would override the tint and leave that icon gray.
            Image(systemName: tab.systemImage)
                .symbolRenderingMode(.monochrome)
        }
    }

    /// Pending-approval count for the Catalog tab badge; nil for other tabs, tvOS, or a zero count
    /// (a `.badge(0)` renders nothing).
    private func catalogBadgeCount(_ tab: AppTab) -> Int? {
        #if os(iOS)
        guard tab == .catalog else { return nil }
        let count = dependencies.pendingRequestsMonitor.pendingApprovalCount ?? 0
        return count > 0 ? count : nil
        #else
        return nil
        #endif
    }

    /// The probed tab set minus the ones the user switched off in settings (Sodalite#62).
    ///
    /// iPhone (compact) also drops Settings from the tab bar so the 6 tabs do not overflow into
    /// the iOS "More" tab, whose nested navigation controller skips the Settings root on back.
    /// Settings is reached via the gear overlay instead. tvOS + iPad keep it as a tab/sidebar item.
    private var displayedTabs: [AppTab] {
        var tabs = availableTabs.filter { !appearance.isTabHidden($0) }
        #if os(iOS)
        if hSizeClass == .compact { tabs = tabs.filter { $0 != .settings } }
        #endif
        return tabs
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(displayedTabs, id: \.self) { tab in
                #if os(iOS)
                if tab == .search {
                    Tab(value: tab, role: .search) {
                        tabContent(for: tab)
                    } label: {
                        tabLabel(tab)
                    }
                } else {
                    Tab(value: tab) {
                        tabContent(for: tab)
                    } label: {
                        tabLabel(tab)
                    }
                    .badge(catalogBadgeCount(tab) ?? 0)
                }
                #else
                Tab(value: tab) {
                    tabContent(for: tab)
                } label: {
                    tabLabel(tab)
                }
                #endif
            }
        }
        #if os(iOS)
        .tabViewStyle(.sidebarAdaptable)
        #else
        .background {
            AppBackgroundView(theme: appearanceTheme, mode: .automatic)
        }
        #endif
        // Fresh TabView (fresh UITabBar) when the active server changes while TabRootView stays mounted (deleting the active server auto-promotes a survivor; isAuthenticated never drops, so the view isn't recreated). A fresh bar reads the tinted appearance at creation. NOT bumped on detail return: detail immersion now alpha-hides the bar instead of removing it, so the bar is never re-templated gray and never needs a rebuild.
        .id(appState.activeServer?.id)
        // Display-only active-profile badge; non-focusable, below the player cover, hidden unless the server has multiple profiles.
        .overlay(alignment: .topTrailing) {
            #if os(iOS)
            if hSizeClass == .compact {
                // Floating gear + badge in the corner; each tab page reserves space for it
                // via .padding(.top, gearChromeHeight) so content never slides under it.
                HStack(spacing: 8) {
                    ActiveUserBadge()
                    settingsGearButton
                }
                .padding(.trailing, 16)
                .padding(.top, 6)
            } else {
                ActiveUserBadge()
            }
            #else
            ActiveUserBadge()
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
                .themedPresentationBackground()
                // Settings is the one surface that raises the Guardian-PIN from above the router,
                // and a cover cannot stack on this sheet. It hosts the prompt itself instead.
                .parentalGateHost(Self.settingsGateHost)
        }
        // The claim is released from the sheet's own state, not from the content's onDisappear:
        // a fullScreenCover takes the content off screen too, so that callback cannot tell a
        // closed sheet from the PIN prompt it just raised.
        .onChange(of: showSettings) { _, presented in
            if !presented { dependencies.parentalGate.popPresenter(Self.settingsGateHost) }
        }
        #endif
        // Foreground Siri Remote play/pause arrives via the responder chain (not MPRemoteCommandCenter), so toggle music here when a track is active.
        .onPlayPauseCommandCompat {
            let coordinator = dependencies.musicPlaybackCoordinator
            if coordinator.currentItem != nil {
                LogTap.shared.note("[NowPlaying] onPlayPauseCommand (tab bar, in-app)")
                coordinator.togglePlayPause()
            }
        }
        .task(id: appState.serverDidSwitch) {
            // TabRootView stays mounted across a switch, so recompute the optional Live TV / Music tabs per server, else the old server's Live TV lingers (wrong backend) and a new server's Music never appears until relaunch.
            let signal = appState.serverDidSwitch
            guard signal != lastProbedServerSwitch else { return }
            let isServerSwitch = lastProbedServerSwitch != -1
            let previousSignal = lastProbedServerSwitch
            lastProbedServerSwitch = signal
            // Latch up front against re-entrant double-probe, but give it back on cancellation (view disappears mid-probe), else the reappear re-fire hits the guard and the Live TV / Music tabs stay missing for the session.
            defer {
                if Task.isCancelled, lastProbedServerSwitch == signal {
                    lastProbedServerSwitch = previousSignal
                }
            }
            if isServerSwitch {
                let base = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
                availableTabs = base
                if !base.contains(selectedTab) {
                    selectedTab = .home
                }
            }

            guard let userID = dependencies.activeUserID else { return }

            // Probe both optional tabs then publish the tab set in ONE assignment. Two separate insertions rebuilt the bar twice, stranding the earlier item (Live TV) on tvOS's gray icon template; one atomic rebuild tints every item uniformly.
            let hasLive = await dependencies.serverHasLiveTV(userID: userID)
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            // Swallow a music-probe error into false so it doesn't skip the assignment and leave Live TV hidden.
            var hasMusic = false
            do {
                hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
            } catch {
                // No music library confirmed; tab stays hidden.
            }
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            // Order: Home, [Live TV,] Catalog, Search, [Music,] Settings.
            var tabs = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
            if hasLive, let homeIndex = tabs.firstIndex(of: .home) {
                tabs.insert(.liveTV, at: homeIndex + 1)
            }
            if hasMusic, let settingsIndex = tabs.firstIndex(of: .settings) {
                tabs.insert(.music, at: settingsIndex)
            }
            if tabs != availableTabs {
                availableTabs = tabs
            }
        }
        // Adding a server (or another profile) authenticates through LoginView -> setAuthenticated, which changes the active server WITHOUT bumping serverDidSwitch, so the probe above never re-fires for the new backend. Re-probe here, else the previous server's Live TV / Music tabs linger and tapping a Live TV tab on a server without Live TV crashes.
        .onReceive(NotificationCenter.default.publisher(for: .loginDidComplete)) { _ in
            loginProbeTask?.cancel()
            loginProbeTask = Task { await recomputeOptionalTabsAfterLogin() }
        }
        // The server is back within a running session (Sodalite#122). Both probes below fail while it
        // is unreachable, so the launch decided "no Live TV, no Music" and the serverDidSwitch latch
        // meant it never asked again: the two tabs stayed gone until the app was force-quit. Answered
        // here rather than by loosening that latch, which guards a device-verified path.
        .task(id: appState.requestContentReload) {
            let signal = appState.requestContentReload
            guard signal > 0, signal != lastHandledContentReload else { return }
            lastHandledContentReload = signal
            defer {
                if Task.isCancelled, lastHandledContentReload == signal {
                    lastHandledContentReload = 0
                }
            }
            await recoverOptionalTabs()
        }
        .onAppear {
            configureTabBarItemAppearance()
        }
        .onChange(of: iconColor) { _, _ in
            // Re-apply on accent change; UITabBarItem.appearance() reads at configure time, not live.
            configureTabBarItemAppearance()
        }
        // Keyed on the DISPLAYED set, not the probed one: a tab the user switched off changes no bar,
        // and switching one back on inserts an item that needs the same re-tint as a probed insertion.
        .onChange(of: displayedTabs) { _, tabs in
            // Hiding the tab you are standing on has to land somewhere that still exists.
            if !tabs.contains(selectedTab) {
                selectedTab = .home
            }
            // Async Live TV / Music insertion rebuilds the UITabBar; re-apply the tint next tick once the new bar exists.
            DispatchQueue.main.async {
                configureTabBarItemAppearance()
            }
        }
    }

    /// Re-evaluates the optional Live TV / Music tabs for the now-active server after a login completion. Drops the previous server's optional tabs first (so a stale, crash-prone Live TV tab is gone immediately), then probes the new backend and republishes. Mirrors the serverDidSwitch probe; kept separate so that device-verified path stays untouched.
    @MainActor
    private func recomputeOptionalTabsAfterLogin() async {
        let base = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
        availableTabs = base
        if !base.contains(selectedTab) {
            selectedTab = .home
        }
        guard let userID = dependencies.activeUserID else { return }

        let hasLive = await dependencies.serverHasLiveTV(userID: userID)
        if Task.isCancelled { return }
        var hasMusic = false
        do {
            hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
        } catch {
            // No music library confirmed; tab stays hidden.
        }
        if Task.isCancelled { return }

        var tabs = base
        if hasLive, let homeIndex = tabs.firstIndex(of: .home) {
            tabs.insert(.liveTV, at: homeIndex + 1)
        }
        if hasMusic, let settingsIndex = tabs.firstIndex(of: .settings) {
            tabs.insert(.music, at: settingsIndex)
        }
        if tabs != availableTabs {
            availableTabs = tabs
        }
    }

    /// Re-probes the optional tabs after an outage hid them, and publishes only if the answer changed.
    ///
    /// Deliberately does NOT clear to the base set first, which is the one thing separating it from
    /// the login variant above: nothing here is stale, it is missing, and dropping tabs that are
    /// already showing would flicker the bar for a signal that usually changes nothing. The two
    /// existing probes are left exactly as they are because both are device-verified against tvOS's
    /// mid-session icon re-templating (see publishing note in the switch probe).
    @MainActor
    private func recoverOptionalTabs() async {
        guard let userID = dependencies.activeUserID else { return }

        let hasLive = await dependencies.serverHasLiveTV(userID: userID)
        if Task.isCancelled { return }
        var hasMusic = false
        do {
            hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
        } catch {
            // No music library confirmed; tab stays hidden.
        }
        if Task.isCancelled { return }

        // One assignment, for the same reason as the other two: two insertions rebuild the bar twice
        // and strand the first item on tvOS's gray icon template.
        var tabs = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
        if hasLive, let homeIndex = tabs.firstIndex(of: .home) {
            tabs.insert(.liveTV, at: homeIndex + 1)
        }
        if hasMusic, let settingsIndex = tabs.firstIndex(of: .settings) {
            tabs.insert(.music, at: settingsIndex)
        }
        if tabs != availableTabs {
            availableTabs = tabs
        }
    }

    /// Tints tab-bar icons + titles via UITabBarAppearance.iconColor at bar creation. NOT per-item .alwaysOriginal images: tvOS re-templates mid-session-inserted items (Live TV / Music) gray and discards baked images, but iconColor tells it which color to template TO. (The gray-on-detail-RETURN is a separate tvOS 26 issue, addressed by presenting details as a full-screen cover so the bar is never hidden/removed.)
    private func configureTabBarItemAppearance() {
        #if os(tvOS)
        let tintUIColor = UIColor(iconColor)

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = tintUIColor
        itemAppearance.selected.iconColor = tintUIColor
        itemAppearance.focused.iconColor = tintUIColor
        // Titles: white at rest, accent when selected or focused.
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: tintUIColor]
        itemAppearance.focused.titleTextAttributes = [.foregroundColor: tintUIColor]

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        // tvOS may lay items stacked or inline by width; set all three so the tint holds.
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        // Future tab bars (a rebuild allocates a new one) inherit this.
        UITabBar.appearance().standardAppearance = appearance

        // Repaint the tab bar that's already on screen.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                Self.applyTabBarAppearance(appearance, tint: tintUIColor, in: window)
            }
        }
        #endif
    }

    private static func applyTabBarAppearance(_ appearance: UITabBarAppearance, tint: UIColor, in view: UIView) {
        if let tabBar = view as? UITabBar {
            tabBar.standardAppearance = appearance
            // The appearance proxy only governs items at CREATION; recolor the live instance directly so an accent change repaints the on-screen bar.
            tabBar.tintColor = tint
            tabBar.unselectedItemTintColor = tint
        }
        for subview in view.subviews {
            applyTabBarAppearance(appearance, tint: tint, in: subview)
        }
    }

    #if os(iOS)
    /// Identifies the Settings sheet as the Guardian-PIN presenter while it is up.
    private static let settingsGateHost = "settings.sheet"
    #endif

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        Group {
            switch tab {
            case .home:
                HomeView()
            case .liveTV:
                // Selection is passed rather than inferred from onAppear: a tab that is not selected
                // keeps its content in the hierarchy, so its clocks have to be told (#96).
                LiveTVTabView(isTabSelected: selectedTab == .liveTV)
            case .catalog:
                CatalogView()
            case .search:
                SearchView()
            case .music:
                MusicHomeView()
            case .settings:
                SettingsView()
            }
        }
        // The verdict is measured once for the whole app, so it is consumed once for the whole app
        // (Sodalite#126). Inside the tab content, never over the tab bar: the fix for the case that
        // has one is in Settings, and the bar is the way there.
        .serverStatusBanner()
        #if os(iOS)
        // Reserve space for the floating settings gear so content never slides under it.
        // padding reliably repositions content, including screens rooted in a NavigationStack
        // (Catalog/Search/...) which ignore a parent safeAreaInset and so would overlap.
        .padding(.top, hSizeClass == .compact ? Self.gearChromeHeight : 0)
        .background {
            AppBackgroundView(
                theme: appearanceTheme,
                mode: .automatic
            )
        }
        #endif
    }

    #if os(iOS)
    static let gearChromeHeight: CGFloat = 56

    private var settingsGearButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.title3)
                .frame(width: 28, height: 28)
                .padding(11)
                .glassEffect(.regular, in: Circle())
                // Make the whole circle the hit target, not just the rendered glyph.
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("tab.settings"))
    }
    #endif
}
