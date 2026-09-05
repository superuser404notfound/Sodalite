import Foundation
import Testing
@testable import Sodalite

@Suite("Route resolver preference matrix")
struct ServerRouteResolverTests {
    private let internalURL = URL(string: "http://10.0.0.2:8096")!
    private let externalURL = URL(string: "https://jf.example.com")!

    private func probe(reachable: Set<URL>) -> @Sendable (URL) async -> Bool {
        { url in reachable.contains(url) }
    }

    /// Sodalite#122. A single slot leaves nothing to choose, which is why the probe used to be
    /// skipped here as pointless work. It is not: "does this address answer from here" is the
    /// question the rest of the app needs, and skipping it is what left a LAN-only server off the
    /// home network proving the same thing one thirty second request timeout at a time.
    @Test("a single internal slot is probed, and reports what it found")
    func internalOnlyIsProbed() async {
        let live = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: nil, lastKnown: nil,
            probe: probe(reachable: [internalURL])
        )
        #expect(live == ServerRouteResolver.Resolved(url: internalURL, route: .internal, isReachable: true))

        // Both answers have to come out of the probe; a hardcoded verdict would pass the line above.
        let dead = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: nil, lastKnown: nil,
            probe: probe(reachable: [])
        )
        #expect(dead == ServerRouteResolver.Resolved(url: internalURL, route: .internal, isReachable: false))
    }

    @Test("a single external slot is probed too")
    func externalOnlyIsProbed() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: nil, externalURL: externalURL, lastKnown: nil,
            probe: probe(reachable: [externalURL])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: externalURL, route: .external, isReachable: true))
    }

    /// The verdict never changes routing. An unreachable single slot is still the URL the session
    /// runs on, because there is no other one and refusing to try would break nothing but the app.
    @Test("an unreachable single slot is still the route")
    func unreachableSingleSlotStillRoutes() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: nil, lastKnown: nil,
            probe: probe(reachable: [])
        )
        #expect(resolved?.url == internalURL)
        #expect(resolved?.route == .internal)
    }

    @Test("both reachable prefers internal")
    func bothReachable() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: .external,
            probe: probe(reachable: [internalURL, externalURL])
        )
        #expect(resolved?.route == .internal)
    }

    @Test("internal dead falls to external")
    func internalDead() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: .internal,
            probe: probe(reachable: [externalURL])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: externalURL, route: .external, isReachable: true))
    }

    @Test("both dead falls back to last-known route")
    func bothDeadLastKnown() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: .external,
            probe: probe(reachable: [])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: externalURL, route: .external, isReachable: false))
    }

    @Test("both dead without last-known defaults to internal")
    func bothDeadDefault() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: nil,
            probe: probe(reachable: [])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: internalURL, route: .internal, isReachable: false))
    }

    @Test("no slots returns nil")
    func noSlots() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: nil, externalURL: nil, lastKnown: nil, probe: { _ in true }
        )
        #expect(resolved == nil)
    }

    @Test("route store round-trip")
    func routeStore() {
        let suite = "route-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerRouteStore(defaults: defaults)
        #expect(store.lastRoute(serverID: "s1") == nil)
        store.setLastRoute(.external, serverID: "s1")
        #expect(store.lastRoute(serverID: "s1") == .external)
        store.setLastRoute(.internal, serverID: "s1")
        #expect(store.lastRoute(serverID: "s1") == .internal)
    }
}
