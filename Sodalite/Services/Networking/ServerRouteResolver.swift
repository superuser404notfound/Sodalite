import Foundation

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
}

/// Reachability probes against unauthenticated status endpoints. Any HTTP
/// response (including 401/5xx) proves the host answers on this route; only
/// transport errors count as unreachable. Per-request ephemeral session,
/// invalidated after use (long-lived sessions retain response data, see the
/// URLSession task-pool leak note in project memory).
enum ServerProbe {
    static let timeout: TimeInterval = 2

    static func jellyfin(_ base: URL) async -> Bool {
        await responds(at: base.appending(path: "System/Info/Public"))
    }

    static func seerr(_ base: URL) async -> Bool {
        await responds(at: base.appending(path: "api/v1/status"))
    }

    private static func responds(at url: URL) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            return response is HTTPURLResponse
        } catch {
            return false
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
