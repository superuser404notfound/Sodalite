import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TabRootView: View {
    @State private var selectedTab: ShellTab = .home
    @State private var availableTabs: [AppTab] = AppTab.baseTabs
    /// Participants with Live TV, from the last tab probe (Sodalite#85).
    @State private var liveTVServerIDs: [String] = []
    /// Participants with a music library, active first (Sodalite#85).
    @State private var musicServerIDs: [String] = []
    /// Last requestContentReload this view answered, so a reappear does not re-probe a signal it
    /// already handled.
    @State private var lastHandledContentReload = 0

    /// serverDidSwitch value of the last completed tab probe. -1 so the first probe fires; a `.task` re-fire on reappear is a no-op while a real switch re-probes.
    @State private var lastProbedServerSwitch = -1
    /// Re-probe triggered by .loginDidComplete (add-server / add-profile authenticates via setAuthenticated WITHOUT bumping serverDidSwitch, so the serverDidSwitch probe never fires for the new server).
    @State private var loginProbeTask: Task<Void, Never>?
    /// Server the tabs currently on screen were probed for. Lets a login completion tell "another
    /// profile on THIS server" (nothing stale, leave the bar alone) from "another server" (the
    /// visible Live TV tab points at a backend that is gone). Sodalite#141.
    @State private var tabsProbedForServerID: String?
    /// The shell as it stood before a profile switch that has not changed it yet, kept so a tab set
    /// arriving from the login probe one or more updates later is still judged against it. Dropped
    /// once the viewer navigates: after that a tab appearing is their own doing.
    @State private var switchOrigin: ProfileShellLayout?
    /// The tab set the bar is showing, published together with the selection that goes with it
    /// (Sodalite#169). A bar that gains tabs in one update and moves its selection in the next leaves
    /// the newly selected page blank on tvOS: its content appears and disappears in the same pass and
    /// stays gone until the viewer leaves the tab and comes back (measured on the tvOS 27 simulator,
    /// the same switch published in one update lands intact). nil until the first change.
    @State private var presentedTabs: [ShellTab]?
    /// Identity of the Settings content, bumped by a profile switch that pops its stack or lands on Home.
    @State private var settingsEpoch = 0
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState
    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    /// Sodalite#81: on a compact iPhone the downloads open from a button beside the gear instead of
    /// a tab. A sixth tab sends the bar into iOS's "More" list, which hid Search and crashed on Music.
    @State private var showDownloads = false
    /// Profiles remembered for the active server, for ActiveUserBadge. Read here because this view is
    /// always on screen and the badge is not until it knows the count (Sodalite#169).
    @State private var rememberedProfileCount = 0
    #if os(iOS)
    @State private var pushStacks = TabPushStacks()
    #endif

    private var appearance: AppearancePreferences {
        dependencies.appearancePreferences
    }

    #if !os(tvOS)
    @ViewBuilder
    private func tabLabel(_ tab: ShellTab) -> some View {
        Label {
            tab.title
        } icon: {
            // .monochrome strips the baked white that "tv" renders hierarchically, which would override the tint and leave that icon gray.
            Image(systemName: tab.systemImage)
                .symbolRenderingMode(.monochrome)
        }
    }

    /// Pending-approval count for the Catalog tab badge; nil for other tabs or a zero count (a
    /// `.badge(0)` renders nothing).
    private func catalogBadgeCount(_ tab: ShellTab) -> Int? {
        guard tab == .catalog else { return nil }
        let count = dependencies.pendingRequestsMonitor.pendingApprovalCount ?? 0
        return count > 0 ? count : nil
    }
    #endif

    /// The probed tab set minus the ones the user switched off in settings (Sodalite#62).
    ///
    /// iPhone (compact) also drops Settings from the tab bar so the 6 tabs do not overflow into
    /// the iOS "More" tab, whose nested navigation controller skips the Settings root on back.
    /// Settings is reached via the gear overlay instead. tvOS + iPad keep it as a tab/sidebar item,
    /// and the Mac moves it to the Settings window.
    private var displayedTabs: [ShellTab] {
        var tabs = AppTab.withDownloads(availableTabs, hasDownloads: showsDownloadsTab)
            .filter { !appearance.isTabHidden($0) }
        #if os(iOS)
        if hSizeClass == .compact { tabs = tabs.filter { $0 != .settings } }
        #elseif os(tvOS)
        tabs = AppTab.withProfiles(tabs, hasProfiles: rememberedProfileCount > 1)
        #elseif os(macOS)
        // The Mac keeps Settings in its own window (Cmd-,), see MacSettingsWindowContent.
        tabs = tabs.filter { $0 != .settings }
        #endif
        var shellTabs = tabs.map(ShellTab.app)
        #if os(tvOS)
        // Pinned libraries follow Home, where the viewer asked for them (Discord, 2026-10-23).
        let libraries = appearance.pinnedLibraryTabs.filter(pinIsReachable).map(ShellTab.library)
        shellTabs.insert(contentsOf: libraries, at: shellTabs.firstIndex(of: .home).map { $0 + 1 } ?? 0)
        #endif
        return shellTabs
    }

    private var tabsOnScreen: [ShellTab] {
        presentedTabs ?? displayedTabs
    }

    private var profileCountIdentity: String {
        "\(appState.activeServer?.id ?? "")|\(appState.activeUser?.id ?? "")|\(appState.serverDidSwitch)"
    }

    private var shellLayout: ProfileShellLayout {
        ProfileShellLayout(profile: appState.profileKey, tabs: displayedTabs, style: appearance.navigationStyle)
    }

    #if !os(tvOS)
    private var tabShell: some View {
        TabView(selection: $selectedTab) {
            ForEach(tabsOnScreen, id: \.self) { tab in
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
            }
        }
    }
    #endif

    /// Sodalite#140. iOS and iPadOS are on the adaptive sidebar unconditionally. tvOS asks the
    /// viewer, because the two styles are a different shell rather than a different skin: the
    /// sidebar hands its screens the full height the top bar reserves for itself. Flipping the
    /// choice changes this view's type, so the whole shell is rebuilt and every tab page starts
    /// fresh. That is why the settings screen commits the change on the way out, not under focus.
    ///
    /// Both tvOS shells are Sodalite's own. The system sidebar cannot be tinted (Apple DTS:
    /// "navigation controls are monochromatic", developer.apple.com/forums/thread/795226), and the
    /// system top bar caps its pill at 1252pt, which cut off the last of six German tabs.
    @ViewBuilder
    private var styledTabShell: some View {
        #if !os(tvOS)
        tabShell
            .tabViewStyle(.sidebarAdaptable)
            #if os(macOS)
            .background(MacSidebarToggleRepair())
            #endif
        #else
        Group {
            if appearance.navigationStyle == .sidebar {
                SidebarShell(tabs: tabsOnScreen, selectedTab: $selectedTab) { tab in
                    tabContent(for: tab)
                }
            } else {
                TopBarShell(tabs: tabsOnScreen, selectedTab: $selectedTab) { tab in
                    tabContent(for: tab)
                }
            }
        }
        .background {
            AppBackgroundView(theme: appearanceTheme, mode: .automatic)
        }
        #endif
    }

    var body: some View {
        styledTabShell
        // Fresh TabView (fresh UITabBar) when the active server changes while TabRootView stays mounted (deleting the active server auto-promotes a survivor; isAuthenticated never drops, so the view isn't recreated). A fresh bar reads the tinted appearance at creation. NOT bumped on detail return: detail immersion now alpha-hides the bar instead of removing it, so the bar is never re-templated gray and never needs a rebuild.
        .id(appState.activeServer?.id)
        // Display-only active-profile badge; non-focusable, below the player cover, hidden unless the server has multiple profiles.
        .overlay(alignment: .topTrailing) {
            #if os(iOS)
            if hSizeClass == .compact {
                // Floating gear + badge in the corner; each tab page reserves space for it
                // via .padding(.top, gearChromeHeight) so content never slides under it.
                // 2 + the badge's own 6 pt trailing inset make the same 8 pt gap as between the
                // circles; the inset stays in the badge, which the other layouts place on its own.
                HStack(spacing: 2) {
                    ActiveUserBadge(rememberedCount: rememberedProfileCount,
                                    onTap: { appState.requestProfilePicker = true })
                    HStack(spacing: 8) {
                        if !dependencies.downloadStore.items.isEmpty {
                            downloadsButton
                        }
                        settingsGearButton
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 6)
                // A pushed page has its own bar up here; hidden, not removed, so the badge keeps
                // its state for the way back.
                .opacity(chromeIsPushedAway ? 0 : 1)
                .allowsHitTesting(!chromeIsPushedAway)
                .animation(.easeInOut(duration: 0.2), value: chromeIsPushedAway)
            } else {
                ActiveUserBadge(rememberedCount: rememberedProfileCount,
                                onTap: { appState.requestProfilePicker = true })
            }
            #elseif os(macOS)
            ActiveUserBadge(rememberedCount: rememberedProfileCount,
                            onTap: { appState.requestProfilePicker = true })
            #endif
            // tvOS has no badge: whenever it would show, the profile tab after Settings carries the
            // name and, unlike the badge, can be focused.
        }
        #if os(iOS)
        .sheet(isPresented: $showDownloads) {
            DownloadsView(onClose: { showDownloads = false })
                .themedPresentationBackground()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
                .themedPresentationBackground()
                .id(settingsEpoch)
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
        // Keyed on identity changes, not read per body, to keep the keychain read cheap. serverDidSwitch
        // is folded in so a same-user server change still re-reads.
        .task(id: profileCountIdentity) {
            refreshRememberedProfileCount()
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
                let base = AppTab.baseTabs
                availableTabs = base
                liveTVServerIDs = []
                musicServerIDs = []
                if let tab = selectedTab.appTab, !base.contains(tab) {
                    selectedTab = .home
                }
            }

            guard let userID = dependencies.activeUserID else { return }

            // Probe both optional tabs then publish the tab set in ONE assignment. Two separate insertions rebuilt the bar twice, stranding the earlier item (Live TV) on tvOS's gray icon template; one atomic rebuild tints every item uniformly.
            let liveIDs = await dependencies.liveTVServerIDs(activeUserID: userID, previouslyCapable: Set(liveTVServerIDs))
            let hasLive = !liveIDs.isEmpty
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            let musicIDs = await dependencies.musicServerIDs(activeUserID: userID, previouslyCapable: Set(musicServerIDs))
            let hasMusic = !musicIDs.isEmpty
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            liveTVServerIDs = liveIDs
            musicServerIDs = musicIDs
            tabsProbedForServerID = appState.activeServer?.id
            if let tabs = OptionalTabPolicy.setToPublishAfterProbe(
                onScreen: availableTabs,
                hasLiveTV: hasLive,
                hasMusic: hasMusic
            ) {
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
        // Sodalite#81: the Downloads a profile sees are its own, so the store follows every switch.
        .task(id: appState.profileKey) {
            dependencies.activateDownloads()
        }
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
        // Combining turned on, a server excluded, or a secondary moved to an address that answers (Sodalite#85).
        .onChange(of: dependencies.sessionRegistry.participantsRevision) { _, _ in
            loginProbeTask?.cancel()
            loginProbeTask = Task { await recoverOptionalTabs() }
        }
        .onChange(of: dependencies.sessionRegistry.routesRevision) { _, _ in
            loginProbeTask?.cancel()
            loginProbeTask = Task { await recoverOptionalTabs() }
        }
        // One handler for the tab set and the selection, so both reach the bar in the same update
        // (see presentedTabs). Keyed on the DISPLAYED set, not the probed one: a tab the user switched
        // off changes no bar, and switching one back on inserts an item that needs the same re-tint as
        // a probed insertion.
        .onChange(of: appState.requestedTab) { _, requested in
            guard let requested else { return }
            appState.requestedTab = nil
            if tabsOnScreen.contains(.app(requested)) {
                selectedTab = .app(requested)
            } else if requested == .downloads {
                #if os(iOS)
                showDownloads = true
                #endif
            }
        }
        .onChange(of: shellLayout) { old, new in
            let armed = switchOrigin
            let result = ProfileShellLayout.resolveSwitch(previous: old, current: new, armedOrigin: armed)
            switchOrigin = result.origin
            let landing = ProfileShellLayout.landingTab(
                current: selectedTab, tabs: new.tabs, landsOnHome: result.landsOnHome)
            presentedTabs = new.tabs
            if landing != selectedTab {
                selectedTab = landing
            }
            // The Settings stack is kept across a switch so a viewer who stays in Settings returns to
            // the screen they started from (#141). A switch that lands on Home has taken them out of
            // it, and the profile list they left open greeted them on the next visit instead of the
            // Settings root (Sodalite#169). One update later, not in this one: rebuilding the page
            // the bar is leaving in the same update as the landing left the bar's selection on the
            // old index, Catalog lit while Home was on screen (reproduced on the tvOS 27 simulator).
            if result.landsOnHome {
                DispatchQueue.main.async {
                    settingsEpoch &+= 1
                }
            }
            if let before = old.profile, let after = new.profile, old.profile != new.profile {
                LogTap.shared.note(
                    "[ProfileSettings] switch \(before.fingerprint) -> \(after.fingerprint), "
                    + "shell changed: \(result.landsOnHome ? "yes" : "not yet, waiting for the tab probe")")
            } else if result.landsOnHome, let origin = armed?.profile {
                LogTap.shared.note(
                    "[ProfileSettings] the shell changed after the switch from \(origin.fingerprint), landing on Home")
            }
        }
        .onChange(of: selectedTab) { _, _ in
            // The viewer moved, so the switch is over: a later tab change is theirs, not its.
            switchOrigin = nil
            // A profile forgotten on the profile tab changes no identity, so the count is re-read
            // on the way out, and the tab goes once only one profile is left.
            refreshRememberedProfileCount()
        }
        .onChange(of: appState.profileKey) { old, new in
            if ProfileShellLayout.switchResetsSettings(
                from: old, to: new,
                escapesGated: dependencies.parentalGateRequiredForSessionAction()
            ) {
                settingsEpoch &+= 1
            }
            // A same-server switch raises neither serverDidSwitch nor loginDidComplete. Shares the
            // login probe's task, so an add-profile login that follows replaces this one.
            if ProfileShellLayout.switchReprobesOptionalTabs(from: old, to: new) {
                loginProbeTask?.cancel()
                loginProbeTask = Task { await recoverOptionalTabs() }
            }
        }
    }

    /// The profile tab keeps one identity: a pick there switches the profile and leaves the tab in
    /// the same update, and re-identifying the page the bar is leaving in that update strands the
    /// bar's selection on the old index (Sodalite#169). It re-reads its cards on appear anyway.
    private func contentIdentity(for tab: ShellTab) -> AnyHashable {
        switch tab.appTab {
        case .settings?: AnyHashable(settingsEpoch)
        case .profiles?: AnyHashable(appState.activeServer?.id)
        default: AnyHashable(appState.profileKey)
        }
    }

    private func refreshRememberedProfileCount() {
        rememberedProfileCount = appState.activeServer.map {
            dependencies.listRememberedUsers(serverID: $0.id).count
        } ?? 0
    }

    /// Re-evaluates the optional Live TV / Music tabs for the now-active server after a login completion, then publishes only a real change.
    ///
    /// The stale-tab drop is conditional, and that is the whole point of Sodalite#141: it costs the
    /// Settings tab its navigation stack (device-verified in Sodalite#62), so it is paid only where
    /// it buys something. Adding a SERVER leaves a Live TV tab pointing at a backend that is gone,
    /// and tapping it crashes the EPG stack, so there the teardown is worth the stack. Adding
    /// another PROFILE on the same server has nothing stale to drop, and the teardown stranded the
    /// user on the settings root instead, after the add-profile focus push had already aimed at the
    /// screen it removed.
    @MainActor
    private func recomputeOptionalTabsAfterLogin() async {
        if let base = OptionalTabPolicy.setToPublishBeforeLoginProbe(
            onScreen: availableTabs,
            probedServerID: tabsProbedForServerID,
            activeServerID: appState.activeServer?.id
        ) {
            availableTabs = base
            if let tab = selectedTab.appTab, !base.contains(tab) {
                selectedTab = .home
            }
        }
        guard let userID = dependencies.activeUserID else { return }

        let liveIDs = await dependencies.liveTVServerIDs(activeUserID: userID, previouslyCapable: Set(liveTVServerIDs))
        let hasLive = !liveIDs.isEmpty
        if Task.isCancelled { return }
        let musicIDs = await dependencies.musicServerIDs(activeUserID: userID, previouslyCapable: Set(musicServerIDs))
        let hasMusic = !musicIDs.isEmpty
        if Task.isCancelled { return }

        liveTVServerIDs = liveIDs
        musicServerIDs = musicIDs
        tabsProbedForServerID = appState.activeServer?.id
        if let tabs = OptionalTabPolicy.setToPublishAfterProbe(
            onScreen: availableTabs,
            hasLiveTV: hasLive,
            hasMusic: hasMusic
        ) {
            availableTabs = tabs
        }
    }

    /// Re-probes the optional tabs after an outage hid them, and publishes only if the answer changed.
    ///
    /// Never clears to the base set first: nothing here is stale, it is missing, and dropping tabs
    /// that are already showing would rebuild the bar for a signal that usually changes nothing
    /// (Sodalite#122). The login probe now makes the same trade for the same reason whenever the
    /// server did not change (Sodalite#141); the server switch is the one site that still clears
    /// unconditionally, because there the tabs on screen belong to a backend that is gone.
    @MainActor
    private func recoverOptionalTabs() async {
        guard let userID = dependencies.activeUserID else { return }

        let liveIDs = await dependencies.liveTVServerIDs(activeUserID: userID, previouslyCapable: Set(liveTVServerIDs))
        let hasLive = !liveIDs.isEmpty
        if Task.isCancelled { return }
        let musicIDs = await dependencies.musicServerIDs(activeUserID: userID, previouslyCapable: Set(musicServerIDs))
        let hasMusic = !musicIDs.isEmpty
        if Task.isCancelled { return }

        liveTVServerIDs = liveIDs
        musicServerIDs = musicIDs
        tabsProbedForServerID = appState.activeServer?.id
        if let tabs = OptionalTabPolicy.setToPublishAfterProbe(
            onScreen: availableTabs,
            hasLiveTV: hasLive,
            hasMusic: hasMusic
        ) {
            availableTabs = tabs
        }
    }

    #if os(iOS)
    /// Identifies the Settings sheet as the Guardian-PIN presenter while it is up.
    private static let settingsGateHost = "settings.sheet"
    #endif

    @ViewBuilder
    private func tabContent(for tab: ShellTab) -> some View {
        Group {
            switch tab {
            case .library(let pin):
                #if os(tvOS)
                libraryTabContent(pin)
                #else
                EmptyView()
                #endif
            case .app(let appTab):
                appTabContent(appTab)
            }
        }
        // Every tab's screens hold the profile they were built for (Live TV captures its user id
        // once, Search its results), so a switch rebuilds them. Settings keeps its stack unless the
        // switch has to take away what the previous profile unlocked, see switchResetsSettings.
        .id(contentIdentity(for: tab))
        // The verdict is measured once for the whole app, so it is consumed once for the whole app
        // (Sodalite#126). Inside the tab content, never over the tab bar: the fix for the case that
        // has one is in Settings, and the bar is the way there.
        .serverStatusBanner()
        #if os(iOS)
        // Room for the floating settings gear, taken by each tab's root page (`reservesShellChrome`)
        // rather than padded around the stack: a pushed detail hides the chrome and owns the top
        // edge. Not for the pages that scroll under the chrome: their inset is a content margin
        // instead (`scrollsUnderShellChrome`), since a padding shrinks the page and it clips its
        // rows at the line below the buttons.
        .environment(\.shellChromeTopInset,
                     hSizeClass == .compact && !Self.scrollsUnderChrome.contains(tab) ? Self.gearChromeHeight : 0)
        .environment(\.detailCoverStack, pushStacks.stack(for: tab))
        // The iPhone's tab bar belongs to the tab pages; a pushed detail takes the whole screen, as
        // the cover it replaced did. Owned here at the tab root, like the tvOS shells own theirs, rather
        // than by the pushed page: a hide a page applies to itself outlives the page (Sodalite#141),
        // and this one is recomputed from the stack that exists. .visible rather than .automatic,
        // which is what a stranded hide survives in.
        .toolbar(hSizeClass == .compact && pushStacks.stack(for: tab).isPushed ? .hidden : .visible, for: .tabBar)
        #endif
        #if !os(tvOS)
        .background {
            AppBackgroundView(
                theme: appearanceTheme,
                mode: .automatic
            )
        }
        #endif
    }

    @ViewBuilder
    private func appTabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .liveTV:
            // Selection is passed rather than inferred from onAppear: a tab that is not selected
            // keeps its content in the hierarchy, so its clocks have to be told (#96).
            #if os(macOS) || os(iOS)
            // Every other tab roots its own stack; this one did not need one while its program
            // pages were covers, and on the Mac and iOS they are pushes (see detailCover).
            ThemeNavigationStack {
                LiveTVTabView(isTabSelected: selectedTab == .liveTV, capableServerIDs: liveTVServerIDs)
                    .reservesShellChrome()
            }
            #else
            LiveTVTabView(isTabSelected: selectedTab == .liveTV, capableServerIDs: liveTVServerIDs)
                .reservesShellBar()
            #endif
        case .catalog:
            CatalogView()
        case .search:
            SearchView()
        case .music:
            MusicHomeView(capableServerIDs: musicServerIDs)
        case .downloads:
            #if !os(tvOS)
            DownloadsView()
            #else
            EmptyView()
            #endif
        case .settings:
            SettingsView()
        case .profiles:
            #if os(tvOS)
            if let server = appState.activeServer {
                // Picking a profile, or the active one, is done with this tab: back to Home.
                LaunchProfilePickerView(server: server, context: .chooser,
                                        onFinished: { selectedTab = .home })
            }
            #else
            EmptyView()
            #endif
        }
    }

    #if os(tvOS)
    /// A pinned library is reachable while its server is: the active one, or a combined participant.
    private func pinIsReachable(_ pin: PinnedLibraryTab) -> Bool {
        guard let serverID = pin.serverID, serverID != appState.activeServer?.id else { return true }
        return dependencies.sessionRegistry.participants.contains { $0.server?.id == serverID }
    }

    /// The grid a My Media tile opens, as the root of its own tab.
    private func libraryTabContent(_ pin: PinnedLibraryTab) -> some View {
        let library = pin.library
        let session = dependencies.sessionRegistry.session(forServerID: pin.serverID)
        let grouping = HomeRowConfig.collectionGrouping(scope: appState.profileKey?.storageScope ?? "")
        let identity = session.isActive
            ? appState.cacheIdentity ?? CacheIdentity(serverID: "", userID: "")
            : CacheIdentity(serverID: session.server?.id ?? "", userID: session.userID)
        return ThemeNavigationStack {
            FilteredGridView(
                title: pin.name,
                query: MyMediaLibraries.gridQuery(for: library, grouping: grouping),
                cacheScope: FilterCacheScope(
                    key: FilterCacheKey.Home.library(id: pin.libraryID, grouping: grouping),
                    identity: identity
                ),
                sortScope: appState.profileKey.map {
                    LibrarySortScope.library(id: pin.libraryID, scope: $0.storageScope)
                },
                hidesAudioPlaylists: MyMediaLibraries.hidesAudioPlaylists(library.libraryType),
                isTabRoot: true
            )
        }
        .environment(\.serverSession, session.isActive ? nil : session)
    }
    #endif

    /// A tab only where the bar has room for it: the iPad sidebar. See `showDownloads`.
    private var showsDownloadsTab: Bool {
        #if os(iOS)
        hSizeClass != .compact && !dependencies.downloadStore.items.isEmpty
        #elseif os(macOS)
        !dependencies.downloadStore.items.isEmpty
        #else
        false
        #endif
    }

    #if os(iOS)
    private var chromeIsPushedAway: Bool { pushStacks.stack(for: selectedTab).isPushed }

    static let gearChromeHeight: CGFloat = 56
    /// The tabs whose root scroll view sits directly under the chrome (`scrollsUnderShellChrome`).
    /// The others start with a fixed header (Live TV's and Catalog's pickers, the search field),
    /// under which their lists end the regular way.
    static let scrollsUnderChrome: Set<ShellTab> = [.home, .music]

    private var downloadsButton: some View {
        chromeCircleButton(systemImage: "arrow.down.circle", label: "tab.downloads") { showDownloads = true }
    }

    private var settingsGearButton: some View {
        chromeCircleButton(systemImage: "gearshape", label: "tab.settings") { showSettings = true }
    }

    /// Dressed, sized and lifted like `ActiveUserBadge` beside it (36 pt avatar plus 6 pt insets,
    /// the same material, edge and shadow, raised by 4 pt), so the corner reads as one strip of
    /// controls rather than a pill next to larger, lower circles of another material.
    private func chromeCircleButton(systemImage: String, label: LocalizedStringKey,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                // The accent, like every close button: these are the app's controls, the badge
                // beside them is a name.
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .padding(6)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                // Make the whole circle the hit target, not just the rendered glyph.
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(y: -4)
        .accessibilityLabel(Text(label))
    }
    #endif
}
