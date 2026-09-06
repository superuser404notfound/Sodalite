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
    }

    private func resolveJellyfinRoute() async {
        guard let server = activeServer else {
            activeJellyfinRoute = nil
            // Nothing to be reachable or not: a signed-out session must not keep the last server's
            // verdict standing behind the login screen.
            appState?.serverReachability = .unknown
            return
        }
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: { await ServerProbe.jellyfin($0) }
        ) else { return }
        guard !Task.isCancelled else { return }

        // One failed probe is a suspicion; two are a verdict. The probe's two second cap is tight
        // on a slow cellular link, and being wrong is no longer free: a failure now paints a screen
        // where it used to fall back silently, so a working remote server on a bad link would flash
        // an error before its first row landed. Paid only on the failure path, and only once.
        var isReachable = resolved.isReachable
        if !isReachable {
            isReachable = await ServerProbe.jellyfin(resolved.url)
            guard !Task.isCancelled else { return }
        }
        publishReachability(url: resolved.url, isReachable: isReachable, server: server)

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
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
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
        // A bad answer starts the watch, a good one lets it fall out on its own next check. Started
        // here rather than at the failure site because this is the one place the verdict changes.
        if verdict.isFailure { startReachabilityWatch() }
    }

    /// A request just died at the transport, which is the only evidence about the SERVER that
    /// exists in that moment (Sodalite#126).
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
    func noteTransportFailure() {
        guard let appState, activeServer != nil, !appState.serverReachability.isFailure else { return }
        guard transportRecheckTask == nil else { return }
        if let last = lastTransportRecheck, ContinuousClock.now - last < ReachabilityRecheck.cooldown {
            return
        }
        lastTransportRecheck = .now
        transportRecheckTask = Task { [weak self] in
            await self?.resolveActiveRoutes()
            self?.transportRecheckTask = nil
        }
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
        reachabilityWatchTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, let appState = self.appState,
                      appState.serverReachability.isFailure, self.activeServer != nil
                else { break }
                do {
                    try await Task.sleep(for: ReachabilityRecheck.delay(forAttempt: attempt))
                } catch {
                    break
                }
                attempt += 1
                await self.resolveActiveRoutes()
            }
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
