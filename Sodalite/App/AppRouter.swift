import SwiftUI
import os.log


struct AppRouter: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase

    /// Guards the initial restore + splash against SwiftUI re-firing `.task` on AppRouter disappear (e.g. player modal on screen), which would otherwise re-show the splash.
    @State private var hasRestored = false
    /// Same `.task` re-fire guard for the server-switch handler: records the last serverDidSwitch value handled so a player dismissal doesn't re-run the probe + Seerr restore.
    @State private var lastHandledServerSwitch = 0

    /// Non-nil while the launch-time profile picker is armed. Picking a profile flips isAuthenticated=true which hides it.
    @State private var launchPickerServer: JellyfinServer?

    /// ContinuousClock (keeps counting through device sleep) instant of the last .background
    /// entry; consumed on return to .active by maybeRequestProfileReprompt (issue #41).
    @State private var lastBackgroundedAt: ContinuousClock.Instant?
    /// Non-nil while the who's-watching cover is up: which server's profiles it offers and why it was
    /// raised (the periodic reprompt for the active server, or a switch to a server this device holds
    /// no resumable session for, Sodalite#74).
    @State private var profileCover: ProfileCoverRequest?

    private struct ProfileCoverRequest: Identifiable {
        let server: JellyfinServer
        let context: LaunchProfilePickerView.Context
        var id: String { server.id }
    }

    /// Item fetched for an incoming deep link plus whether it should start playing; drives the fullScreenCover (non-nil = sheet shown).
    ///
    /// One value, not an item plus a parallel Bool: as two separate `@State`s the cover could be
    /// built from the new item while still reading the old flag, and a TopShelf play link then
    /// landed on the detail page instead of playing (cold launch, where the flag is written in the
    /// same update as the item).
    @State private var deepLinkPresentation: DeepLinkPresentation?

    /// Drives the WhatsNew fullScreenCover after the splash on a release-boundary launch; dismiss callback stamps the version seen.
    @State private var showWhatsNew = false

    /// Drives the NowPlaying fullScreenCover off the coordinator's nowPlayingPresentationRequest bump.
    @State private var showNowPlaying = false

    /// Both platforms: its change callback is an iOS concern, but the path STATUS it snapshots is
    /// what tells an unreachable server apart from a device with no network (Sodalite#122).
    @State private var pathObserver = NetworkPathObserver()

    /// (server, user) identity of the active session. Background music is scoped to it and must stop when it
    /// changes: server switch, same-server profile switch (switchToUser, which does NOT bump serverDidSwitch),
    /// active-server removal, logout (activeServer/activeUser -> nil), and tvOS-user change all land here.
    private var activeSessionIdentity: String {
        "\(appState.activeServer?.id ?? "none")|\(appState.activeUser?.id ?? "none")"
    }

    /// Edge-triggered active flag: keys a `.task` so the monitor refreshes on foreground, not on every phase change.
    private var scenePhaseIsActive: Bool { scenePhase == .active }

    /// False while something is presented above the router and hosts the PIN cover itself: the
    /// profile picker here, or a `parentalGateHost()` surface such as the iOS Settings sheet.
    private var routerOwnsTheGate: Bool {
        profileCover == nil && dependencies.parentalGate.presenterStack.isEmpty
    }

    /// Refresh the pending-approval count and, on iOS, keep the app-icon badge + notifications in sync.
    private func refreshPending() async {
        #if os(iOS)
        await PendingRequestsSync.refreshAndSync(
            monitor: dependencies.pendingRequestsMonitor,
            preferences: dependencies.seerrNotificationPreferences,
            jellyfinServerID: dependencies.activeServer?.id,
            jellyfinUserID: dependencies.activeUserID
        )
        #else
        await dependencies.pendingRequestsMonitor.refresh()
        #endif
    }

    var body: some View {
        ZStack {
            if appState.isAuthenticated {
                TabRootView()
            } else {
                Group {
                    if let server = launchPickerServer {
                        LaunchProfilePickerView(server: server)
                    } else {
                        ServerDiscoveryView()
                    }
                }
                .themedRootBackground()
            }

            // Now-Playing is surfaced in the Music tab + track tap (not a global bar, which covered detail action buttons); both bump the coordinator's presentation request, observed below.

            // Splash overlays until restore finishes AND the minimum display time elapses, then cross-fades out (avoids a jarring snap on a <100ms restore).
            if appState.isLoading {
                SplashView()
                    .transition(.opacity)
            }

            // Masks the stale detail view (~1-2s) between deep-link player dismiss and the new fullScreenCover sliding in.
            if appState.isResolvingDeepLink {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
                    .transition(.opacity)
            }

            // Topmost, splash included: with Local Network access off, every screen underneath is
            // showing a wrong reason for the same one cause (Sodalite#92). Raised only once nothing
            // in the app is getting through, so a session another route is serving stays uncovered.
            #if os(iOS)
            if appState.isLocalNetworkDenied {
                LocalNetworkDeniedView {
                    await recheckLocalNetworkAccess()
                }
                .transition(.opacity)
            }
            #endif
        }
        .animation(.easeOut(duration: 0.4), value: appState.isLoading)
        .animation(.easeInOut(duration: 0.2), value: appState.isResolvingDeepLink)
        .animation(.easeInOut(duration: 0.2), value: appState.isLocalNetworkDenied)
        // Keep the Catalog pending-requests badge fresh: recompute when the app comes forward, when the
        // Seerr connection flips, and on the admin-queue change signal. iOS/iPadOS badge; inert on tvOS.
        .task(id: scenePhaseIsActive) {
            if scenePhaseIsActive {
                #if os(iOS)
                await recheckLocalNetworkAccess()
                #endif
                await refreshPending()
                await dependencies.cloudSync?.fetchNow()
                #if os(iOS)
                dependencies.scheduleRouteResolve()
                #endif
            }
        }
        .task(id: appState.isSeerrConnected) {
            if appState.isSeerrConnected {
                await refreshPending()
            } else {
                dependencies.pendingRequestsMonitor.reset()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seerrPendingRequestsShouldRefresh)) { _ in
            Task { await refreshPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seerrRequestsDidChange)) { _ in
            Task { await refreshPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidApplyChanges)) { _ in
            // Fresh install: the initial restore finishes on an empty keychain and
            // routes to discovery before the first cloud-sync fetch lands. Re-run
            // the restore when synced data arrives so the profile picker appears
            // without an app relaunch.
            guard !appState.isAuthenticated, !appState.isLoading else { return }
            Task { await restoreSession() }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            // Queue the next background poll when leaving the foreground, only while opted in.
            if phase == .background, dependencies.seerrNotificationPreferences.notifyPendingRequests {
                PendingRequestsBackgroundRefresh.schedule()
            }
        }
        #endif
        .task {
            guard !hasRestored else { return }
            hasRestored = true
            await restoreSession()
        }
        .task {
            // The change callback re-resolves the route on a Wi-Fi handoff, which is an iOS
            // concern. The monitor itself runs on both: NetworkPathSnapshot is what tells an
            // unreachable server apart from a device with no network at all (Sodalite#122).
            #if os(iOS)
            pathObserver.onPathChange = { dependencies.scheduleRouteResolve() }
            #endif
            pathObserver.start()
        }
        .task(id: appState.pendingDeepLinkItemID) {
            await resolvePendingDeepLink()
        }
        .task(id: appState.requestContinueWatching) {
            await resolveContinueWatchingRequest()
        }
        // A switch to a server this device holds no resumable session for (Sodalite#74). Nothing was
        // switched, so the current session stands: offer that server's profiles (and the sign-in behind
        // "Add another profile") and let the pick do the switching.
        .task(id: appState.pendingProfilePickerServerID) {
            guard let serverID = appState.pendingProfilePickerServerID else { return }
            appState.pendingProfilePickerServerID = nil
            guard let server = dependencies.listKnownServers().first(where: { $0.id == serverID }) else { return }
            if appState.isAuthenticated {
                profileCover = ProfileCoverRequest(server: server, context: .switchServer)
            } else {
                // Already on the launch picker: re-point it rather than stack a cover on top of it.
                // Also what stops that picker from lingering on the previous server after a switch out
                // of its own server sheet.
                launchPickerServer = server
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .background {
                lastBackgroundedAt = ContinuousClock().now
            }
            guard scenePhase == .active else { return }
            // Consume on every .active entry: a stale instant must never survive into a later task re-fire.
            let backgroundedAt = lastBackgroundedAt
            lastBackgroundedAt = nil
            // Skip until the initial restore has run, so a cold launch does not re-prompt on top of it.
            guard hasRestored else { return }
            maybeRequestProfileReprompt(backgroundedAt: backgroundedAt)
        }
        .task(id: appState.serverDidSwitch) {
            guard appState.serverDidSwitch > 0 else { return }
            guard appState.serverDidSwitch != lastHandledServerSwitch else { return }
            let handledSignal = appState.serverDidSwitch
            lastHandledServerSwitch = handledSignal
            // Latch rollback on cancellation (player cover presenting mid-probe cancels AFTER the latch); else the reappear re-fire is guarded away and the switch is left half-applied.
            defer {
                if Task.isCancelled, lastHandledServerSwitch == handledSignal {
                    lastHandledServerSwitch = handledSignal - 1
                }
            }
            // Capture the probe target ONCE: re-reading activeServer after the await could observe a NEWER switch's pointer and authenticate a mixed identity.
            let probedServer = dependencies.activeServer
            do {
                let user = try await dependencies.probeActiveUser()
                // Superseded mid-probe (newer switch re-keyed the task): stale result must not touch AppState/Seerr.
                guard !Task.isCancelled else { return }
                if let user, let server = probedServer {
                    appState.setAuthenticated(server: server, user: user)
                    // The probe carries the server's own name; re-stamp the caches so the switched-to identity is right on the next cold launch too.
                    dependencies.persistActiveUserName(user.name, userID: user.id, serverID: server.id)
                    // Restore the per-(server,user) Seerr session so Catalog reflects the new identity.
                    let outcome = await dependencies.syncSeerrSession(
                        forJellyfinUserID: user.id,
                        jellyfinServerID: server.id
                    )
                    guard !Task.isCancelled else { return }
                    if case .connected(let seerrServer, let seerrUser) = outcome {
                        appState.setSeerrConnected(server: seerrServer, user: seerrUser)
                        dependencies.scheduleRouteResolve()
                    } else {
                        appState.disconnectSeerr()
                    }
                    // Last, because it delays nothing the user is waiting for: the profiles of the
                    // server just switched to are a cache nobody has re-read since it was last
                    // active (Sodalite#90).
                    let reconcile = await dependencies.reconcileRememberedProfiles()
                    // The pass can end the session it rode on (the profile was deleted on the
                    // server between the probe above and this request). Route it here rather than
                    // through requestSessionReroute, whose bump would re-key this very task.
                    if reconcile.endedActiveSession, !Task.isCancelled {
                        launchPickerServer = dependencies.activeServer
                        appState.isAuthenticated = false
                    }
                } else {
                    // Token expired, no remembered user, or the active server was removed with no
                    // successor: route to the picker for the new active server, or fall through to
                    // ServerDiscoveryView when there is none. Assign unconditionally so a nil
                    // activeServer clears any stale picker instead of stranding a deleted server.
                    launchPickerServer = dependencies.activeServer
                    appState.isAuthenticated = false
                }
            } catch {
                // Cancellation is never a verdict on the target server: a superseded switch cancels this task and URLSession throws, which we must not misread as a transport failure and roll back the user's NEWER pick.
                guard !Task.isCancelled else { return }
                // Avoid rollback loops: if appState already holds the active server (just rolled back, probe still failing), let the failure stand for the next user action to surface.
                if let previous = appState.activeServer,
                   previous.id != dependencies.activeServer?.id {
                    try? dependencies.rollbackSwitch(to: previous.id)
                }
            }
        }
        .fullScreenCover(item: $deepLinkPresentation) { presentation in
            NavigationStack {
                DetailRouterView(item: presentation.item, autoPlay: presentation.autoPlay)
            }
            #if os(iOS)
            // tvOS dismisses this deep-link cover via the Menu button; iOS needs a touch
            // close. Floating overlay (not a toolbar) because detail views hide the nav bar.
            .overlay(alignment: .topLeading) {
                Button {
                    deepLinkPresentation = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .padding()
                }
                .buttonStyle(.plain)
            }
            #endif
            .pausesAppBackgroundMotion()
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(onClose: { showNowPlaying = false })
                .pausesAppBackgroundMotion()
        }
        .onChange(of: dependencies.musicPlaybackCoordinator.nowPlayingPresentationRequest) { _, _ in
            showNowPlaying = true
        }
        // Background music is scoped to the active (server, user) session; stop it whenever that identity
        // changes (server switch, profile switch, active-server removal, logout). No-op when nothing is playing.
        .onChange(of: activeSessionIdentity) { _, _ in
            if dependencies.musicPlaybackCoordinator.currentItem != nil {
                dependencies.musicPlaybackCoordinator.stop()
            }
        }
        .fullScreenCover(isPresented: $showWhatsNew) {
            if let entry = Changelog.latest {
                WhatsNewView(entry: entry) {
                    ChangelogPreferences.markCurrentSeen()
                    showWhatsNew = false
                }
                .themedPresentationBackground()
            }
        }
        // The router hosts the PIN cover for everything that lives at its own level. A surface
        // presented above it (the iOS Settings sheet) registers with the gate and hosts its own,
        // because a cover cannot stack on a sheet from the same hosting controller.
        .fullScreenCover(item: Binding(
            get: { routerOwnsTheGate ? dependencies.parentalGate.activeRequest : nil },
            set: { if $0 == nil { dependencies.parentalGate.resolve(false) } }
        )) { request in
            PINEntryView(mode: .unlock(reason: request.reason)) { unlocked in
                dependencies.parentalGate.resolve(unlocked)
            }
            .pausesAppBackgroundMotion()
        }
        .fullScreenCover(item: $profileCover) { cover in
            LaunchProfilePickerView(
                server: cover.server,
                context: cover.context,
                onFinished: { profileCover = nil }
            )
            .themedPresentationBackground()
            // The AppRouter-level PIN cover can't stack on this cover (one cover per host view),
            // so the gate presents from inside while this one is up.
            .fullScreenCover(item: Binding(
                get: { dependencies.parentalGate.activeRequest },
                set: { if $0 == nil { dependencies.parentalGate.resolve(false) } }
            )) { request in
                PINEntryView(mode: .unlock(reason: request.reason)) { unlocked in
                    dependencies.parentalGate.resolve(unlocked)
                }
                .pausesAppBackgroundMotion()
            }
        }
        .onChange(of: appState.isLoading) { _, isLoading in
            // Splash finished: fire What's-New on a release-boundary crossing. isAuthenticated lets the prefs layer tell a fresh install (don't pester) from a pre-Changelog upgrade (0.3.2 and earlier never wrote lastSeenVersion).
            guard !isLoading else { return }
            if ChangelogPreferences.shouldShowOnLaunch(isExistingUser: appState.isAuthenticated) {
                showWhatsNew = true
            } else {
                ChangelogPreferences.bootstrapIfNeeded()
            }
        }
    }

    /// Feeds the active user's first Resume item through the deep-link channel. Triggered by ContinueWatchingIntent; the intent stays trivial to respect tvOS-Siri's "no async work" voice-invocation policy.
    private func resolveContinueWatchingRequest() async {
        guard appState.requestContinueWatching else { return }

        // Cold-launch wait (Siri may hand control before restoreSession finishes), 8s cap so a fresh install / picker doesn't poll for the process lifetime and pop a sheet minutes later.
        let waitDeadline = Date().addingTimeInterval(8)
        while !appState.isAuthenticated, !Task.isCancelled, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Cancelled (re-keyed/disappeared): leave the signal armed so the restarted task still acts on it.
        guard !Task.isCancelled else { return }
        guard appState.isAuthenticated, let user = appState.activeUser else {
            appState.requestContinueWatching = false
            return
        }

        let response = try? await dependencies.jellyfinLibraryService.getResumeItems(
            userID: user.id,
            mediaType: "Video",
            limit: 1
        )
        guard !Task.isCancelled else { return }
        appState.requestContinueWatching = false
        if let item = response?.items.first {
            appState.pendingDeepLinkItemID = item.id
        }
    }

    /// Re-asks the system about the address the standing Local Network denial was measured on, and
    /// takes the overlay down if it is gone. Runs when the app comes forward, because returning from
    /// Settings is exactly how the answer changes, and from the overlay's own retry button.
    ///
    /// Clearing the flag is not enough on its own: the screens behind it gave up while the
    /// permission was off and would still be showing that failure, so this also asks them to reload.
    #if os(iOS)
    private func recheckLocalNetworkAccess() async {
        guard appState.isLocalNetworkDenied else { return }
        let denied = await LocalNetworkAccess.stillDenied()
        guard !denied else { return }
        appState.isLocalNetworkDenied = false
        appState.requestContentReload &+= 1
    }
    #endif

    /// Waits for auth, fetches the item, triggers the fullScreenCover. Clears the pending id last so a repeat tap on the same TopShelf cell re-fires.
    private func resolvePendingDeepLink() async {
        guard let id = appState.pendingDeepLinkItemID else {
            appState.pendingDeepLinkAutoPlay = false
            appState.isResolvingDeepLink = false
            return
        }
        // Cold-launch race: URL arrives before restoreSession finishes. Wait, 8s cap, since a missing-token state can leave isAuthenticated false at the picker and an unbounded wait would lock the user behind our overlay.
        let waitDeadline = Date().addingTimeInterval(8)
        while !appState.isAuthenticated, !Task.isCancelled, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Cancelled (re-keyed/disappeared): don't consume the pending id; the restarted task picks it up with full time.
        guard !Task.isCancelled else { return }
        guard appState.isAuthenticated, let user = appState.activeUser else {
            // Couldn't restore in time: drop the pending link + overlay so the user can interact with picker/discovery.
            appState.pendingDeepLinkItemID = nil
            appState.pendingDeepLinkAutoPlay = false
            appState.isResolvingDeepLink = false
            return
        }
        // Dismiss any active player before the new sheet (TopShelf often fires over a backgrounded paused player, else its modal stays on top of the new cover). Two-step: (1) bump requestPlayerDismissal so detail views flip showPlayer (keeps the binding path consistent on return); (2) walk the modal chain to dismiss PlayerHostController directly, since binding-driven dismiss proved unreliable across scene-foreground.
        // A deep link is deliberate navigation: drop the profile cover (continue as current profile,
        // abandon a pending server switch) and cancel any PIN challenge started from it, else its
        // continuation later runs a stale switch.
        if profileCover != nil {
            profileCover = nil
            if dependencies.parentalGate.activeRequest != nil {
                dependencies.parentalGate.resolve(false)
            }
        }
        appState.requestPlayerDismissal &+= 1
        PlayerModalDismisser.dismissActive(logPrefix: "[AppRouter]")
        // Let UIKit finish the dismiss before the new fullScreenCover, else it races and SwiftUI warns "presenting from a VC that is being dismissed" or the modal never lands.
        try? await Task.sleep(for: .milliseconds(250))

        let item = try? await dependencies.jellyfinItemService.getItemDetail(
            userID: user.id,
            itemID: id
        )
        guard !Task.isCancelled else { return }
        deepLinkPresentation = item.map {
            DeepLinkPresentation(item: $0, autoPlay: appState.pendingDeepLinkAutoPlay)
        }
        // Hold the overlay past the cover binding flip so the slide-in fully obscures the view before we fade out. Pending id cleared LAST: this task is keyed on it, so nilling earlier self-cancels at the next suspension and the 300ms hold never happens (stale-view flash returns).
        try? await Task.sleep(for: .milliseconds(300))
        appState.isResolvingDeepLink = false
        appState.pendingDeepLinkAutoPlay = false
        appState.pendingDeepLinkItemID = nil
    }

    /// Caller consumes lastBackgroundedAt on every .active entry (a player dismissal re-fires the
    /// scenePhase task while still .active, and must not re-prompt); this only decides whether to
    /// arm the cover.
    private func maybeRequestProfileReprompt(backgroundedAt: ContinuousClock.Instant?) {
        guard let backgroundedAt else { return }
        // Never arm over a sibling cover (one fullScreenCover per host view) or a deep link in flight.
        guard deepLinkPresentation == nil, !showNowPlaying, !showWhatsNew, profileCover == nil,
              appState.pendingDeepLinkItemID == nil, !appState.isResolvingDeepLink
        else { return }
        guard let server = appState.activeServer else { return }
        let should = ProfileRepromptPolicy.shouldReprompt(
            elapsed: backgroundedAt.duration(to: ContinuousClock().now),
            interval: dependencies.authPreferences.profileReprompt,
            launchBehavior: dependencies.authPreferences.launchBehavior,
            isAuthenticated: appState.isAuthenticated,
            rememberedCount: dependencies.listRememberedUsers(serverID: server.id).count,
            isPlayerActive: PlayerModalPresence.isPlayerActive,
            tvUserChanged: false
        )
        if should { profileCover = ProfileCoverRequest(server: server, context: .reprompt) }
    }

    private func restoreSession() async {
        appState.isLoading = true
        let splashStart = Date()

        // Fresh install: give the first iCloud fetch a bounded head start so a
        // synced household lands on the profile picker instead of discovery.
        if dependencies.listKnownServers().isEmpty,
           dependencies.cloudSync?.isEnabled == true {
            appState.isCloudSyncProbing = true
            await dependencies.cloudSync?.waitForInitialSync(timeout: 6)
            appState.isCloudSyncProbing = false
        }

        await performRestore()

        // Hold the splash for at least the minimum so the brand moment
        // isn't reduced to a flash on a fast restore path.
        let elapsed = Date().timeIntervalSince(splashStart)
        let remaining = SplashView.minimumDisplayDuration - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        appState.isLoading = false
    }

    private func performRestore() async {
        // Fire-and-forget: StoreKit is independent of the Jellyfin restore and shouldn't block the splash; isSupporter starts cached and flips live.
        Task { @MainActor in
            await dependencies.storeKitService.refreshSupporterStatus()
            await dependencies.storeKitService.loadProducts()
        }

        // Restore policy (pointer repair, default-server promotion, migrations, launch routing) lives in SessionRestorer; this view only maps the outcome onto AppState + picker state.
        let outcome = SessionRestorer(env: dependencies).restore()
        let syncSeerr: Bool
        switch outcome {
        case .authenticated(let server, let user):
            appState.setAuthenticated(server: server, user: user)
            Task { await refreshActiveUserIdentity(expectedUserID: user.id) }
            syncSeerr = true
        case .picker(let server, let wantsSeerr):
            launchPickerServer = server
            syncSeerr = wantsSeerr
        case .discovery:
            syncSeerr = false
        }
        guard syncSeerr else { return }

        // Seerr restore (policy in syncSeerrSession), with legacy fallback for pre-0.3.0 logins. Runs
        // AFTER the AppState flip so TabRootView mounts under the splash and loads concurrently with
        // the probe.
        //
        // Fire-and-forget, like the StoreKit refresh above and for the same reason (Sodalite#122).
        // It makes a live request, and a secondary service must never be able to hold the splash for
        // a primary one's launch: a LAN-only Seerr off the home network used to park the brand
        // screen for a full thirty second timeout before the tab bar existed. Catalog already reacts
        // to the connection landing late, since it keys on `appState.isSeerrConnected`.
        Task { @MainActor in
            let seerrOutcome = await dependencies.syncSeerrSession(
                forJellyfinUserID: appState.activeUser?.id,
                jellyfinServerID: appState.activeServer?.id,
                allowLegacyFallback: true
            )
            if case .connected(let seerrServer, let seerrUser) = seerrOutcome {
                appState.setSeerrConnected(server: seerrServer, user: seerrUser)
                dependencies.scheduleRouteResolve()
            }
        }
    }

    /// The first thing a restored session asks the server: who this token resolves to (the Policy
    /// block drives the canDeleteContent gate, and keychain-bootstrapped users carry policy: nil),
    /// and whether it still resolves at all. `expectedUserID` discards the result if a racing profile
    /// switch changed the active user.
    ///
    /// A refused token used to be swallowed here, so a session whose user had been deleted on the
    /// server entered the app and failed one request at a time. Now the container drops that profile
    /// and this lands on the server's picker instead, in one update so the discovery screen never
    /// flashes between the two (Sodalite#90).
    private func refreshActiveUserIdentity(expectedUserID: String) async {
        guard let serverID = appState.activeServer?.id else { return }
        switch await dependencies.refreshActiveUserDetails(
            expectedUserID: expectedUserID,
            serverID: serverID
        ) {
        case .kept(let fresh):
            if let fresh { appState.activeUser = fresh }
            // The session stands, so its token can speak for the profiles beside it: hold them
            // against the server's own user table.
            if await dependencies.reconcileRememberedProfiles().endedActiveSession {
                launchPickerServer = dependencies.activeServer
                appState.isAuthenticated = false
            }
        case .rejected:
            launchPickerServer = dependencies.activeServer
            appState.isAuthenticated = false
        }
    }
}
