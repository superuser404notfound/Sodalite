import Foundation
import os

/// Picks the live URL for a server, and says whether it answered.
///
/// Both slots are probed in parallel; internal wins whenever it answers, external is the fallback,
/// and when neither answers the last-known route keeps the session on whatever worked before.
///
/// A single-slot server is probed too, which is the whole of Sodalite#122. With one slot there is
/// nothing to choose, so the probe used to be skipped as pointless work: the resolver was built to
/// answer *which of two*, and "neither" was not in its return type. But "does this address answer
/// from here" is the question the rest of the app actually needs, it is the only place the app asks
/// it cheaply (two seconds, capped, against an unauthenticated endpoint), and a LAN-only server is
/// exactly the configuration that goes dark off the home network. Skipping the probe there meant
/// the app rediscovered the answer one thirty second request timeout at a time, under a spinner.
///
/// `isReachable` never changes routing. An unreachable address is still returned, and still used;
/// only what the app is willing to say about it changes.
enum ServerRouteResolver {
    struct Resolved: Equatable, Sendable {
        let url: URL
        let route: ServerRoute
        /// Did `url` answer its probe? False on the both-slots-dead fallback, and on a single slot
        /// that did not respond.
        let isReachable: Bool
    }

    static func resolve(
        internalURL: URL?,
        externalURL: URL?,
        lastKnown: ServerRoute?,
        probe: @escaping @Sendable (URL) async -> Bool
    ) async -> Resolved? {
        switch (internalURL, externalURL) {
        case (nil, nil):
            return nil
        case (let internalURL?, nil):
            return Resolved(url: internalURL, route: .internal, isReachable: await probe(internalURL))
        case (nil, let externalURL?):
            return Resolved(url: externalURL, route: .external, isReachable: await probe(externalURL))
        case (let internalURL?, let externalURL?):
            async let externalReachable = probe(externalURL)
            if await probe(internalURL) {
                // externalReachable is left unawaited on purpose: scope exit cancels it, and the
                // internal route has already won. Awaiting it would put the external slot's full
                // probe cap in front of every launch on the home network.
                return Resolved(url: internalURL, route: .internal, isReachable: true)
            }
            if await externalReachable {
                return Resolved(url: externalURL, route: .external, isReachable: true)
            }
            let fallback = lastKnown ?? .internal
            return Resolved(
                url: fallback == .internal ? internalURL : externalURL,
                route: fallback,
                isReachable: false
            )
        }
    }

    /// The slots a Seerr route may choose between.
    ///
    /// Seerr has no endpoint that names one installation (`api/v1/status` reports a version), so an
    /// answer at its LAN address cannot be checked the way a Jellyfin one is, and on another network
    /// whatever sits there would win the route and be sent the session cookie (audit NETWORK-2). Its
    /// internal slot is therefore trusted only while Jellyfin's identity-checked internal address
    /// answers: that is the proof of being on the home network. A single slot is left alone, there
    /// is no choice to make.
    static func seerrSlots(
        internalURL: URL?, externalURL: URL?, onVerifiedHomeNetwork: Bool
    ) -> (internalURL: URL?, externalURL: URL?) {
        guard internalURL != nil, externalURL != nil, !onVerifiedHomeNetwork else {
            return (internalURL, externalURL)
        }
        return (nil, externalURL)
    }
}

/// Reachability probes against unauthenticated status endpoints. Per-request ephemeral session,
/// invalidated after use (long-lived sessions retain response data, see the URLSession task-pool
/// leak note in project memory).
enum ServerProbe {
    static let timeout: TimeInterval = 2

    /// Whether this status counts as the server answering FOR THIS SESSION.
    ///
    /// It used to be "any HTTP response at all", which is the right rule for picking between two
    /// addresses (both may sit behind the same proxy, and a 401 from the right host still says the
    /// host is there) and the wrong one for the question the app now asks of it. Measured on
    /// 2026-09-06: a Jellyfin that is still booting answers every request with a 503 and its own
    /// "Jellyfin Startup" page for the better part of a minute. The probe called that reachable, the
    /// app cleared its error screen, reloaded everything into 503s and painted the screen straight
    /// back, and the watch had already stopped because the verdict said all was well. The user saw
    /// the interface flash once and then had to press Try Again by hand.
    ///
    /// So 5xx is not an answer: it is the server saying it cannot serve. Everything else stays one,
    /// 401 and 404 included, because those come from a server that is up and merely disagreeing.
    static func answers(statusCode: Int) -> Bool {
        !(500...599).contains(statusCode)
    }

    /// The endpoint whose answer means a session can run, and it is deliberately NOT
    /// `System/Info/Public` (Sodalite#126).
    ///
    /// Measured on 2026-09-06, Jellyfin 10.11.11, from a log: while the server is booting, its
    /// startup page answers 503 for the API but `System/Info/Public` is served normally, which is
    /// reasonable of it (a client asking who you are should get an answer before you are ready to
    /// work). The consequence here was that the probe asked the one endpoint that cannot show the
    /// condition it was meant to detect: it reported reachable, the app cleared its error screen,
    /// every real request came back 503, and the recheck watch stopped because the verdict said all
    /// was well. Even the 5xx trigger could not save it, because the re-measure it kicked off asked
    /// the same forgiving endpoint again.
    ///
    /// `Users/Public` is the login screen's own endpoint. It is unauthenticated, present on every
    /// Jellyfin, and behind the startup gate, so its answer means what this probe claims to mean. A
    /// server that hides its user list answers 403 or an empty list, and both still count.
    ///
    /// Server DISCOVERY still asks `System/Info/Public`, and should: identifying a host is exactly
    /// what that endpoint is for, and it is a different question from whether the host is ready.
    static let jellyfinReadinessPath = "Users/Public"

    static func jellyfin(_ base: URL) async -> Bool {
        await responds(at: base.appending(path: jellyfinReadinessPath))
    }

    /// Readiness plus identity, for a probe whose winner becomes the session's address.
    ///
    /// Readiness alone crowned any host that answered, 401 and 404 included, so on another network
    /// whatever sat at the LAN address (a router page, someone else's Jellyfin) won the route and
    /// was sent the access token, the `api_key` URLs and the Top Shelf mirror (audit NETWORK-2). A
    /// slot now only counts when `System/Info/Public` names the server this session belongs to.
    /// A server stored without an id (discovery tolerates one) has nothing to compare against.
    static func jellyfin(_ base: URL, expectedServerID: String) async -> Bool {
        guard !expectedServerID.isEmpty else { return await jellyfin(base) }
        async let ready = outcome(at: base.appending(path: jellyfinReadinessPath))
        let failure: String?
        switch await outcome(at: base.appending(path: "System/Info/Public")) {
        case .failed(let reason):
            failure = "System/Info/Public \(reason)"
        case .answered(_, let response) where !(200...299).contains(response.statusCode):
            failure = "System/Info/Public HTTP \(response.statusCode)"
        case .answered(let data, _) where !identifies(data, as: expectedServerID):
            failure = "answers as server \(answeredID(data)), session expects \(expectedServerID.prefix(8))"
        case .answered:
            switch await ready {
            case .failed(let reason): failure = "\(jellyfinReadinessPath) \(reason)"
            case .answered(_, let response) where !answers(statusCode: response.statusCode):
                failure = "\(jellyfinReadinessPath) HTTP \(response.statusCode)"
            case .answered: failure = nil
            }
        }
        noteProbeFailure(failure, host: base.host() ?? "?")
        return failure == nil
    }

    /// Why the last identity probe of each host failed, so a failure that keeps repeating is logged
    /// once (Sodalite#199). The verdict line names only the host, and a working server that the
    /// strip calls unreachable leaves three suspects that look the same from outside: an identity
    /// that does not match, a readiness endpoint answering 5xx, and the two second cap.
    private static let lastFailures = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func noteProbeFailure(_ failure: String?, host: String) {
        let isNew = lastFailures.withLock { failures in
            defer { failures[host] = failure }
            return failure != nil && failures[host] != failure
        }
        if isNew, let failure {
            LogTap.shared.note("[network] probe of \(host) failed: \(failure)")
        }
    }

    private static func answeredID(_ body: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (object?["Id"] as? String).map { String($0.prefix(8)) } ?? "(no Id)"
    }

    /// Whether a `System/Info/Public` body names this server. Jellyfin writes the id as 32 hex
    /// digits; compared without case or dashes so a server that formats it as a UUID still matches.
    static func identifies(_ body: Data, as expectedServerID: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["Id"] as? String
        else { return false }
        return normalizedServerID(id) == normalizedServerID(expectedServerID)
    }

    private static func normalizedServerID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func seerr(_ base: URL) async -> Bool {
        await responds(at: base.appending(path: "api/v1/status"))
    }

    private static func responds(at url: URL) async -> Bool {
        guard let (_, response) = await fetch(url) else { return false }
        return answers(statusCode: response.statusCode)
    }

    private static func fetch(_ url: URL) async -> (Data, HTTPURLResponse)? {
        guard case .answered(let data, let response) = await outcome(at: url) else { return nil }
        return (data, response)
    }

    /// Not an `Error`: the reason is a log line, never a viewer's.
    private enum ProbeOutcome {
        case answered(Data, HTTPURLResponse)
        case failed(String)
    }

    private static func outcome(at url: URL) async -> ProbeOutcome {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(
            configuration: config, delegate: ServerTrustDelegate.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failed("no HTTP response")
            }
            return .answered(data, http)
        } catch let error as URLError {
            return .failed("no answer (URLError \(error.code.rawValue))")
        } catch {
            return .failed("no answer (\(type(of: error)))")
        }
    }
}

/// Last route that worked per server id; seeds the synchronous client setup
/// on launch and the both-probes-dead fallback.
struct ServerRouteStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastRoute(serverID: String) -> ServerRoute? {
        defaults.string(forKey: key(serverID)).flatMap(ServerRoute.init(rawValue:))
    }

    func setLastRoute(_ route: ServerRoute, serverID: String) {
        defaults.set(route.rawValue, forKey: key(serverID))
    }

    private func key(_ serverID: String) -> String { "serverRoute.\(serverID)" }
}
