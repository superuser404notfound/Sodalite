import Foundation

/// Dual-URL route resolution. Synchronous session paths set an optimistic
/// baseURL via preferredURL(lastKnown:) for first-frame correctness; this
/// extension then probes and corrects asynchronously. A route change only
/// affects new requests; active playback keeps its absolute stream URL.
extension DependencyContainer {
    /// Debounce/cancel seam for the iOS path-change and foreground triggers.
    func scheduleRouteResolve() {
        routeResolveTask?.cancel()
        routeResolveTask = Task { [weak self] in
            await self?.resolveActiveRoutes()
        }
    }

    func resolveActiveRoutes() async {
        await resolveJellyfinRoute()
        await resolveSeerrRoute()
        await resolveSecondaryRoutes()
    }

    /// A client of its own for signing in to `server`: no token, and an address the live session
    /// never sees.
    ///
    /// The sign-in flow used to borrow the live `jellyfinClient` and repoint it, while it still held
    /// the active session's token. Adding a second server therefore sent that token to it with every
    /// background request (and with Quick Connect's authenticate call, every time), a cancelled add
    /// left the session talking to the wrong server, and a restore landing mid-login moved the
    /// client back so the password typed for one server was posted to the other (audit SESSION-1).
    /// Only `saveSession` / `switchToUser` write the live client.
    func makeSignInClient(for server: JellyfinServer) -> JellyfinClient {
        let client = JellyfinClient(httpClient: httpClient)
        client.baseURL = preferredURL(for: server)
        return client
    }

    /// Points a sign-in client at whichever of a server's addresses answers, for a server that is
    /// not the active one yet.
    ///
    /// Signing in happens before there IS an active server, so `resolveJellyfinRoute` bails out and
    /// the whole sign-in flow ran on `preferredURL(for:)` alone: the last route that worked, or the
    /// internal slot when there is no last route. Somebody whose last session was at home therefore
    /// spent the entire sign-in talking to a LAN address that cannot be reached from a phone on
    /// cellular, and the only symptom is that signing in works at home and nowhere else.
    ///
    /// Returns after the probe so callers can await it before their first request. The optimistic
    /// URL is set first regardless, so a screen that draws before this lands is not left pointing
    /// at nothing, and an unreachable server still gets an address to fail against and report.
    @discardableResult
    func resolveSignInRoute(for server: JellyfinServer, client: JellyfinClient) async -> URL {
        let optimistic = preferredURL(for: server)
        client.baseURL = optimistic
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: { [jellyfinProbe, id = server.id] in await jellyfinProbe($0, id) }
        ) else { return optimistic }
        serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
        client.baseURL = resolved.url
        return resolved.url
    }

    private func resolveJellyfinRoute() async {
        guard let server = activeServer else {
            activeJellyfinRoute = nil
            isOnVerifiedHomeNetwork = false
            // Nothing to be reachable or not: a signed-out session must not keep the last server's
            // verdict standing behind the login screen.
            appState?.serverReachability = .unknown
            return
        }
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: { [jellyfinProbe, id = server.id] in await jellyfinProbe($0, id) }
        ) else { return }
        guard !Task.isCancelled else { return }

        // One failed probe is a suspicion; two are a verdict. The probe's two second cap is tight
        // on a slow cellular link, and being wrong is no longer free: a failure now paints a screen
        // where it used to fall back silently, so a working remote server on a bad link would flash
        // an error before its first row landed. Paid only on the failure path, and only once.
        var isReachable = resolved.isReachable
        if !isReachable {
            isReachable = await jellyfinProbe(resolved.url, server.id)
            guard !Task.isCancelled else { return }
        }
        publishReachability(url: resolved.url, isReachable: isReachable, server: server)
        isOnVerifiedHomeNetwork = resolved.route == .internal && isReachable

        serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
        activeJellyfinRoute = resolved.route
        guard jellyfinClient.baseURL != resolved.url else { return }

        jellyfinClient.baseURL = resolved.url
        rewriteSessionMirror(server: server, resolvedURL: resolved.url)
        NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
    }

    private func resolveSeerrRoute() async {
        guard let server = appState?.activeSeerrServer, seerrClient.sessionCookie != nil else {
            activeSeerrRoute = nil
            return
        }
        let slots = ServerRouteResolver.seerrSlots(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            onVerifiedHomeNetwork: isOnVerifiedHomeNetwork
        )
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: slots.internalURL,
            externalURL: slots.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: seerrRouteKey(server.id)),
            probe: { await ServerProbe.seerr($0) }
        ) else { return }
        guard !Task.isCancelled else { return }

        serverRouteStore.setLastRoute(resolved.route, serverID: seerrRouteKey(server.id))
        activeSeerrRoute = resolved.route
        guard seerrClient.baseURL != resolved.url else { return }

        seerrClient.baseURL = resolved.url
        NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
    }

    /// Publishes what the probe just measured, so the rest of the app shares one verdict instead of
    /// each screen proving the same thing again against a thirty second timeout (Sodalite#122).
    ///
    /// The classification happens here, once, for the same reason: this is where both facts the
    /// verdict needs are in hand at the same moment, the address that was probed and whether the
    /// server carries a second slot to fall back on.
    ///
    /// A verdict that improves back to reachable also asks the features to reload. Home gave up
    /// while the server was unreachable and holds nothing that would bring it back on its own; this
    /// is the same signal the return from a Local Network denial raises, for the same reason.
    private func publishReachability(url: URL, isReachable: Bool, server: JellyfinServer) {
        guard let appState else { return }
        let reading = NetworkPathSnapshot.shared.current
        let verdict = ServerReachability.classify(
            probedURL: url,
            answered: isReachable,
            hasAlternateSlot: server.internalURL != nil && server.externalURL != nil,
            pathIsSatisfied: reading?.isSatisfied,
            isAttachedToALocalNetwork: reading?.isAttachedToALocalNetwork
        )
        let previous = appState.serverReachability
        guard verdict != previous else { return }
        appState.serverReachability = verdict
        LogTap.shared.note("[network] \(server.name) is \(verdict) at \(url.host() ?? "?")")
        if verdict == .reachable, previous.isFailure {
            appState.requestContentReload += 1
        }
        // Sodalite#81: first contact after launch, and every return after an outage, hands the
        // progress made offline back to the server.
        if verdict == .reachable { runDownloadSync() }
        // A bad answer starts the watch, a good one lets it fall out on its own next check. Started
        // here rather than at the failure site because this is the one place the verdict changes.
        if verdict.isFailure { startReachabilityWatch() }
    }

    /// A request just went unserved, which is the only evidence about the SERVER that exists in
    /// that moment (Sodalite#126).
    ///
    /// Every other trigger is an event about the DEVICE: a path change, a foreground, a server
    /// switch, a login. On a phone the reported case, walking out of the house, is a path change, so
    /// the gap stayed hidden. On an Apple TV nothing about the device's network moves when the
    /// server dies, so the app measured once at launch and believed it for the rest of the session,
    /// which is every outage an Apple TV can have.
    ///
    /// Bounded three ways, because a failing session produces failures by the dozen: only while the
    /// verdict still says the server is fine, since past that the watch below owns the question;
    /// only one re-measure in flight; and not twice inside the cooldown, so a server that answers
    /// the probe while its API keeps failing cannot turn every request into another probe.
    func noteServerDidNotServe() {
        guard let appState, activeServer != nil, !appState.serverReachability.isFailure else { return }
        guard transportRecheckTask == nil else { return }
        if let last = lastTransportRecheck, ContinuousClock.now - last < ReachabilityRecheck.cooldown {
            return
        }
        lastTransportRecheck = .now
        LogTap.shared.note("[network] a request went unserved, re-measuring")
        transportRecheckTask = Task { [weak self] in
            await self?.resolveActiveRoutes()
            self?.transportRecheckTask = nil
        }
    }

    /// A person just pressed Try Again (Sodalite#126).
    ///
    /// Re-measures AND raises the recovery signal unconditionally, instead of leaving the signal to
    /// the verdict transition in `publishReachability`. That transition only fires where the app had
    /// correctly recorded the failure first, and a session that LAUNCHED into an outage may never
    /// have recorded one: what a launch learns once it never learns again, so the optional tabs, the
    /// profile picture and the Seerr session stayed exactly as the outage left them while Home
    /// reloaded and made the screen look repaired. Measured on iPhone and on Apple TV alike, which
    /// is what said the cause was not the trigger set but the signal itself.
    ///
    /// A retry is by definition someone saying the last failure is obsolete, which is precisely what
    /// the signal means, so it does not need the verdict's permission to say it. Raising it while
    /// the server is still down costs one failed refresh round and no state: an identity refresh
    /// that cannot reach the server now keeps what it had.
    func retryAfterFailure() async {
        await resolveActiveRoutes()
        appState?.requestContentReload += 1
    }

    /// Keeps asking while the answer is bad, and stops as soon as it is not.
    ///
    /// The mirror of the trigger above, and needed for the same reason: nothing on the device
    /// changes when the server comes BACK either. Without it a session would sit on a stale failure
    /// until someone pressed a button, which on a screen nobody is looking at is forever.
    ///
    /// The probe it drives is an unauthenticated GET capped at two seconds, so the steady state
    /// costs two requests a minute against a host that is already down, and it stops on the first
    /// answer rather than on a timer.
    func startReachabilityWatch() {
        guard reachabilityWatchTask == nil else { return }
        LogTap.shared.note("[network] recheck watch armed")
        reachabilityWatchTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, let appState = self.appState,
                      appState.serverReachability.isFailure, self.activeServer != nil
                else { break }
                let delay = ReachabilityRecheck.delay(forAttempt: attempt)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
                attempt += 1
                // Only while the schedule is still backing off, plus one line when it settles. The
                // diagnostic buffer holds 300 lines, so a watch ticking every thirty seconds through
                // an outage that lasts the evening would flush out the very log that explains it,
                // and a long outage is exactly when someone reads it. After this the watch is silent
                // until it stops, and the absence of that line is what says it is still asking.
                if delay < ReachabilityRecheck.ceiling {
                    LogTap.shared.note("[network] recheck attempt \(attempt) after \(delay)")
                } else if attempt == ReachabilityRecheck.attemptsBeforeCeiling {
                    LogTap.shared.note("[network] recheck settling to one attempt every \(delay), quietly")
                }
                await self.resolveActiveRoutes()
            }
            LogTap.shared.note("[network] recheck watch stopped")
            self?.reachabilityWatchTask = nil
        }
    }

    /// Jellyfin and Seerr ids live in the same store; prefix avoids collisions.
    func seerrRouteKey(_ id: String) -> String { "seerr.\(id)" }

    func preferredURL(for server: JellyfinServer) -> URL {
        server.preferredURL(lastKnown: serverRouteStore.lastRoute(serverID: server.id))
    }

    func preferredSeerrURL(for server: SeerrServer) -> URL {
        server.preferredURL(lastKnown: serverRouteStore.lastRoute(serverID: seerrRouteKey(server.id)))
    }

    /// TopShelf reads absolute image URLs from the mirror; keep it on the live route.
    private func rewriteSessionMirror(server: JellyfinServer, resolvedURL: URL) {
        guard
            let token = try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id)),
            let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        else { return }
        SharedSessionMirror.write(
            serverURL: resolvedURL,
            userID: userID,
            accessToken: token
        )
    }
}
