import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Dual-URL route resolution. Synchronous session paths set an optimistic
/// baseURL via preferredURL(lastKnown:) for first-frame correctness; this
/// extension then probes and corrects asynchronously. A LAN address gets no
/// credentials until its probe has named this server (`RouteGate`, audit
/// NET-201). A route change only affects new requests; active playback keeps
/// its absolute stream URL.
extension DependencyContainer {
    /// The one owner of a route re-measure (audit SHELL-R202). Every trigger, a launch, a switch, a
    /// path change, a failed request, the recheck watch and Try Again, lands here, and a newer pass
    /// cancels the one still running, so two passes never race each other's address and verdict
    /// writes. Returns the pass so a caller that needs the answer can await it.
    @discardableResult
    func scheduleRouteResolve() -> Task<Void, Never> {
        routeResolveTask?.cancel()
        let pass = Task { [weak self] in
            guard let self else { return }
            await self.resolveActiveRoutes()
        }
        routeResolveTask = pass
        return pass
    }

    /// The live client now belongs to another session (or to none), or its server's addresses were
    /// edited. A pass that started before must not write its address, verdict or Top Shelf mirror
    /// into what the client is now (audit SHELL-201), so the generation moves before the new pass.
    func liveRouteDidChange() {
        routeGeneration &+= 1
        forgetVerifiedRoutes(includingSecondaries: false)
        scheduleRouteResolve()
    }

    /// The device may be on another network now, where the home LAN addresses belong to somebody
    /// else, so nothing proved before counts (audit NET-201).
    func networkPathDidChange() {
        forgetVerifiedRoutes(includingSecondaries: true)
        scheduleRouteResolve()
    }

    /// The moments the network may have changed under the app, answered synchronously: the path
    /// monitor's own update (its callback is debounced a second), and on iOS the return from the
    /// background, which comes before the monitor has caught up. Without it the foreground work sent
    /// the token, and the Seerr cookie, on the old network's proof (audit review R-ROUTE-3).
    func observeRouteProofInvalidations() {
        let center = NotificationCenter.default
        var names: [Notification.Name] = [.networkPathWillChange]
        #if os(iOS)
        names.append(UIApplication.willEnterForegroundNotification)
        #endif
        for name in names {
            // queue nil: delivered on the posting thread, before the next foreground step runs.
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.networkPathDidChange() }
            }
        }
        #if os(macOS)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkPathDidChange() }
        }
        #endif
    }

    private func forgetVerifiedRoutes(includingSecondaries: Bool) {
        jellyfinClient.routeGate?.reset()
        if includingSecondaries {
            for session in sessionRegistry.participants where !session.isActive {
                session.client.routeGate?.reset()
            }
        }
        mirroredSessionURL = nil
        isOnVerifiedHomeNetwork = false
        // Seerr's LAN slot rides on that proof, so its cookie goes to the public slot until it is back.
        if let seerr = appState?.activeSeerrServer, seerrClient.baseURL != nil {
            seerrClient.baseURL = preferredSeerrURL(for: seerr)
        }
    }

    func resolveActiveRoutes() async {
        let generation = routeGeneration
        // Secondaries have their own addresses and gates, so they need not queue behind the
        // active server's slower slot.
        async let secondaries: Void = resolveSecondaryRoutes(generation: generation)
        await resolveJellyfinRoute(generation: generation)
        await resolveSeerrRoute(generation: generation)
        await secondaries
    }

    /// The identity probe, reporting each answer to `gate` as it lands, so a request held for one
    /// address goes the moment that address proves itself rather than after the slower slot.
    func verifyingProbe(
        serverID: String, gate: RouteGate?, epoch: UInt64
    ) -> @Sendable (URL) async -> Bool {
        { [jellyfinAnswer, weak gate] url in
            let answer = await jellyfinAnswer(url, serverID)
            // Cancelled because the other slot won: that says nothing about this one.
            if !Task.isCancelled { await gate?.record(url, identity: answer.identity, epoch: epoch) }
            return answer.isReady
        }
    }

    /// Still the pass the current session asked for: not replaced by a newer pass, and no session
    /// change since it started.
    func isCurrentRoutePass(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == routeGeneration
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
    ///
    /// It carries a gate of its own that the route probe started here settles, so nothing it sends
    /// (a typed password, a token to revoke, a PIN-recovery login) reaches a LAN address before
    /// that address proved it is this server (audit review R-ROUTE-4).
    func makeSignInClient(for server: JellyfinServer) -> JellyfinClient {
        let client = JellyfinClient(httpClient: httpClient)
        client.baseURL = preferredURL(for: server)
        let gate = RouteGate(isEnforced: verifiesServerIdentity)
        gate.reset()
        client.routeGate = gate
        Task { [weak self, weak client] in
            guard let self, let client else { return }
            await self.resolveSignInRoute(for: server, client: client)
        }
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
        let gate = client.routeGate
        let epoch = gate?.epoch ?? 0
        let optimistic = preferredURL(for: server)
        client.baseURL = optimistic
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: verifyingProbe(serverID: server.id, gate: gate, epoch: epoch)
        ) else {
            gate?.settle(epoch: epoch)
            return optimistic
        }
        serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
        client.baseURL = resolved.url
        await proveIfStillUnproved(resolved.url, serverID: server.id, gate: gate, epoch: epoch)
        gate?.settle(epoch: epoch)
        return resolved.url
    }

    /// The route probe's two second cap is for picking between slots. The address that won, if it
    /// did not prove itself inside that cap, gets the patient identity check before the epoch
    /// settles, so a slow LAN server is not shut out of its own session (audit review R-ROUTE-1).
    func proveIfStillUnproved(_ url: URL, serverID: String, gate: RouteGate?, epoch: UInt64) async {
        guard let gate, gate.isEnforced, !gate.isSettled, gate.epoch == epoch,
              RouteGate.needsProof(url), !gate.hasVerified(url)
        else { return }
        let identity = await jellyfinIdentity(url, serverID)
        gate.record(url, identity: identity, epoch: epoch)
    }

    private func resolveJellyfinRoute(generation: UInt64) async {
        let gate = jellyfinClient.routeGate
        let epoch = gate?.epoch ?? 0
        guard let server = activeServer else {
            activeJellyfinRoute = nil
            isOnVerifiedHomeNetwork = false
            // Nothing to be reachable or not: a signed-out session must not keep the last server's
            // verdict standing behind the login screen.
            appState?.serverReachability = .unknown
            gate?.settle(epoch: epoch)
            return
        }
        let probe = verifyingProbe(serverID: server.id, gate: gate, epoch: epoch)
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: probe
        ) else {
            gate?.settle(epoch: epoch)
            return
        }
        guard isCurrentRoutePass(generation) else { return }

        // One failed probe is a suspicion; two are a verdict. The probe's two second cap is tight
        // on a slow cellular link, and being wrong is no longer free: a failure now paints a screen
        // where it used to fall back silently, so a working remote server on a bad link would flash
        // an error before its first row landed. Paid only on the failure path, and only once.
        var isReachable = resolved.isReachable
        if !isReachable {
            isReachable = await probe(resolved.url)
            guard isCurrentRoutePass(generation) else { return }
        }
        publishReachability(url: resolved.url, isReachable: isReachable, server: server)
        isOnVerifiedHomeNetwork = resolved.route == .internal && isReachable

        serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
        activeJellyfinRoute = resolved.route
        let moved = jellyfinClient.baseURL != resolved.url
        jellyfinClient.baseURL = resolved.url
        await proveIfStillUnproved(resolved.url, serverID: server.id, gate: gate, epoch: epoch)
        guard isCurrentRoutePass(generation) else { return }
        // After the move, so a held request reads the address it is released to.
        gate?.settle(epoch: epoch)
        // A queued download waits for this proof, and nothing else starts it again (R-ROUTE-6).
        downloadManager?.serversChanged()

        // The Top Shelf extension sends the token wherever the mirror says, so the mirror is
        // written here, for an address credentials may go to, and not by the session writes.
        if jellyfinClient.verifiedBaseURL == resolved.url, mirroredSessionURL != resolved.url {
            rewriteSessionMirror(server: server, resolvedURL: resolved.url)
            mirroredSessionURL = resolved.url
        }
        guard moved else { return }
        NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
    }

    private func resolveSeerrRoute(generation: UInt64) async {
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
        guard isCurrentRoutePass(generation), appState?.activeSeerrServer?.id == server.id else { return }

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
        let isLANAddress = LocalNetworkAccess.isGoverned(url)
        if isReachable, isLANAddress, let subnets = reading?.subnets {
            ServerHomeNetworks.record(subnets, serverID: server.id)
        }
        let verdict = ServerReachability.classify(
            probedURL: url,
            answered: isReachable,
            hasAlternateSlot: server.internalURL != nil && server.externalURL != nil,
            pathIsSatisfied: reading?.isSatisfied,
            isAttachedToALocalNetwork: reading?.isAttachedToALocalNetwork,
            isOnAForeignLocalNetwork: !isReachable && isLANAddress && ServerHomeNetworks.isForeign(
                current: reading?.subnets ?? [],
                known: ServerHomeNetworks.known(serverID: server.id),
                serverHost: url.host() ?? ""
            )
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
    func noteServerDidNotServe(baseURL: URL) {
        // Only the active server's address: a Combine secondary rides the same HTTP client, and
        // its failures re-measured this route every cooldown (audit NET-208).
        guard baseURL == jellyfinClient.baseURL else { return }
        guard let appState, activeServer != nil, !appState.serverReachability.isFailure else { return }
        guard transportRecheckTask == nil else { return }
        if let last = lastTransportRecheck, ContinuousClock.now - last < ReachabilityRecheck.cooldown {
            return
        }
        lastTransportRecheck = .now
        LogTap.shared.note("[network] a request went unserved, re-measuring")
        let pass = scheduleRouteResolve()
        transportRecheckTask = Task { [weak self] in
            await pass.value
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
        var pass = scheduleRouteResolve()
        // A launch, a Seerr connect or a path change may replace this pass; the reload has to wait
        // for the one that actually decides, or it lands on the old verdict (audit review R-ROUTE-9).
        while true {
            await pass.value
            guard let current = routeResolveTask, current != pass else { break }
            pass = current
        }
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
                await self.scheduleRouteResolve().value
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

    /// Never the LAN slot of a two-slot Seerr before Jellyfin's internal address has proved this is
    /// the home network: Seerr cannot be asked who it is, and the session cookie goes with the first
    /// request (audit NET-201).
    func preferredSeerrURL(for server: SeerrServer) -> URL {
        let slots = ServerRouteResolver.seerrSlots(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            onVerifiedHomeNetwork: isOnVerifiedHomeNetwork
        )
        let allowed = SeerrServer(id: server.id, internalURL: slots.internalURL, externalURL: slots.externalURL)
        return allowed.preferredURL(lastKnown: serverRouteStore.lastRoute(serverID: seerrRouteKey(server.id)))
    }

    /// Whether a 401/403 from `url` speaks for the Seerr server (audit NET-202). A LAN address does
    /// only on the proved home network; anywhere else it may be anybody's.
    func seerrRefusalCounts(at url: URL?) -> Bool {
        seerrMayTrust(url)
    }

    /// Whether Seerr at `url` may get the cookie and be believed. Seerr cannot be asked who it is,
    /// so a LAN address is trusted on the proved home network, or where Jellyfin has no LAN slot to
    /// prove it with: there is nothing to wait for, and a genuine 401 must still end a dead session
    /// (audit review R-ROUTE-8).
    func seerrMayTrust(_ url: URL?) -> Bool {
        guard verifiesServerIdentity else { return true }
        guard let url else { return false }
        return !RouteGate.needsProof(url) || isOnVerifiedHomeNetwork || activeServer?.internalURL == nil
    }

    /// Whether a 401 from `url` speaks for `server` (audit NET-202): the address still the one the
    /// session uses, and it answers `System/Info/Public` with this server's id right now. Asked only
    /// on a refusal, so it costs nothing on the normal path, and it also catches a proxy in front
    /// that answers 401 for everything.
    func jellyfinRefusalCounts(at url: URL?, server: JellyfinServer) async -> Bool {
        guard verifiesServerIdentity else { return true }
        guard let url, url == jellyfinClient.baseURL else { return false }
        return await jellyfinIdentity(url, server.id) == .matches
    }

    /// Readiness and identity as one yes/no, the shape the route resolver and older tests use.
    /// Setting it stubs both halves: a yes is this server and ready, a no is silence.
    var jellyfinProbe: @Sendable (URL, String) async -> Bool {
        get {
            let answer = jellyfinAnswer
            return { await answer($0, $1).isReady }
        }
        set {
            jellyfinAnswer = { await newValue($0, $1) ? .ready : .silent }
            jellyfinIdentity = { await newValue($0, $1) ? .matches : .noAnswer }
        }
    }

    /// Off for a container over a test double (see `RouteGate.isEnforced`). Tests switch it on.
    var verifiesServerIdentity: Bool {
        get { jellyfinClient.routeGate?.isEnforced ?? false }
        set {
            jellyfinClient.routeGate?.isEnforced = newValue
            sessionRegistry.verifiesServerIdentity = newValue
        }
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
