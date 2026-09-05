import Testing
import Foundation
@testable import Sodalite

/// Sodalite#116. FilterCache keys used to carry no identity, and correctness was held up by
/// `clearAll()` on every server and every profile switch, which threw away both sides of the hop.
/// These pin the replacement: the identity is in the filename, eviction reaches exactly as far as
/// the event that caused it, the directory is bounded by identity count instead of emptied, and a
/// directory written by the previous filename format leaves nothing unreachable behind.
struct FilterCacheScopingTests {
    private static let a1 = CacheIdentity(serverID: "serverA", userID: "user1")
    private static let a2 = CacheIdentity(serverID: "serverA", userID: "user2")
    private static let b1 = CacheIdentity(serverID: "serverB", userID: "user1")

    private func makeCache() -> (cache: FilterCache, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilterCacheScoping-\(UUID().uuidString)", isDirectory: true)
        return (FilterCache(directory: directory), directory)
    }

    private func item(_ id: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: id)
    }

    private func fileNames(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Backdates every file belonging to one identity, so the trim's recency ranking is testable
    /// without sleeping. Matches on the filename shape the trim itself parses.
    private func stamp(_ identity: CacheIdentity, in directory: URL, to date: Date) {
        let marker = ".\(identity.serverID).\(identity.userID)."
        for name in fileNames(in: directory) where name.contains(marker) {
            try? FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: directory.appendingPathComponent(name).path
            )
        }
    }

    // MARK: - Key shape

    /// The one real collision in the old scheme: `Home.genre(name:)` is keyed by a human name, so
    /// "Action" on two servers was literally the same file.
    @Test func oneGenreNameOnTwoServersIsTwoEntries() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = FilterCacheKey.Home.genre(name: "Action")
        cache.setHomeFilterItems([item("a")], filterKey: key, identity: Self.a1)
        cache.setHomeFilterItems([item("b1"), item("b2")], filterKey: key, identity: Self.b1)

        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1)?.map(\.id) == ["a"])
        #expect(cache.homeFilterItems(filterKey: key, identity: Self.b1)?.map(\.id) == ["b1", "b2"])
    }

    /// Two profiles on one server carry different library permissions and watched flags, so they
    /// are as separate as two servers are.
    @Test func twoProfilesOnOneServerAreTwoEntries() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = FilterCacheKey.Home.library(id: "lib1", grouping: .system)
        cache.setHomeFilterItems([item("one")], filterKey: key, identity: Self.a1)
        cache.setHomeFilterItems([item("two")], filterKey: key, identity: Self.a2)

        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1)?.map(\.id) == ["one"])
        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a2)?.map(\.id) == ["two"])
    }

    /// The two slices share the key space by construction (a genre name and a catalog id could
    /// collide), so the slice stays in the filename ahead of the identity.
    @Test func theTwoSlicesDoNotShareAFile() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        cache.setHomeFilterItems([item("home")], filterKey: "shared", identity: Self.a1)
        cache.setCatalogPage([], totalPages: 7, filterKey: "shared", identity: Self.a1)

        #expect(cache.homeFilterItems(filterKey: "shared", identity: Self.a1)?.map(\.id) == ["home"])
        #expect(cache.catalogPage(filterKey: "shared", identity: Self.a1)?.totalPages == 7)
    }

    /// The layout the eviction and trim parses depend on. Pinned because a change here silently
    /// turns every existing entry unreachable, which reads as "the cache stopped working".
    @Test func theFilenameCarriesFormatSliceAndIdentity() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        cache.setHomeFilterItems([item("a")], filterKey: FilterCacheKey.Home.genre(name: "Action"), identity: Self.a1)

        #expect(fileNames(in: directory) == ["v2.homeItems.serverA.user1.home-genre-Action.json"])
    }

    /// A genre name may hold a "." ("Marvel Studios 2.0"), and "." separates the filename segments.
    /// The key is therefore encoded without it, else the identity parse reads part of the key as
    /// the server and the entry escapes every eviction that should reach it.
    @Test func aKeyHoldingADotStillBelongsToItsIdentity() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = FilterCacheKey.Home.genre(name: "Marvel Studios 2.0")
        cache.setHomeFilterItems([item("a")], filterKey: key, identity: Self.a1)
        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1)?.count == 1)

        cache.evict(identity: Self.b1)
        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1) != nil)

        cache.evict(identity: Self.a1)
        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1) == nil)
    }

    /// A "/" ("Action/Adventure") would become a path separator and the write would fail inside a
    /// `try?` into a permanent silent miss.
    @Test func aKeyHoldingASlashRoundTrips() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = FilterCacheKey.Home.genre(name: "Action/Adventure")
        cache.setHomeFilterItems([item("a")], filterKey: key, identity: Self.a1)

        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1)?.map(\.id) == ["a"])
        #expect(fileNames(in: directory).count == 1)
    }

    // MARK: - Eviction reach

    /// Removing a profile takes its entries and nothing else: the sibling profile on the same box
    /// keeps its rows, and so does the same user id on another server.
    @Test func evictingOneIdentityLeavesItsNeighboursStanding() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        for identity in [Self.a1, Self.a2, Self.b1] {
            cache.setHomeFilterItems([item("x")], filterKey: "k", identity: identity)
            cache.setCatalogPage([], totalPages: 1, filterKey: "k", identity: identity)
        }

        cache.evict(identity: Self.a1)

        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.a1) == nil)
        #expect(cache.catalogPage(filterKey: "k", identity: Self.a1) == nil)
        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.a2) != nil)
        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.b1) != nil)
    }

    /// Deleting an item and removing a server are both server-wide facts: every profile on that box
    /// loses its cached grids, no profile on another box does.
    @Test func evictingOneServerTakesEveryProfileOnIt() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        for identity in [Self.a1, Self.a2, Self.b1] {
            cache.setHomeFilterItems([item("x")], filterKey: "k", identity: identity)
            cache.setCatalogPage([], totalPages: 1, filterKey: "k", identity: identity)
        }

        cache.evict(serverID: "serverA")

        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.a1) == nil)
        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.a2) == nil)
        #expect(cache.catalogPage(filterKey: "k", identity: Self.a2) == nil)
        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.b1) != nil)
        #expect(cache.catalogPage(filterKey: "k", identity: Self.b1) != nil)
    }

    /// The factory reset keeps its reach: nothing readable survives it, whatever wrote it.
    @Test func clearAllLeavesNothing() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        for identity in [Self.a1, Self.a2, Self.b1] {
            cache.setHomeFilterItems([item("x")], filterKey: "k", identity: identity)
        }
        try? Data().write(to: directory.appendingPathComponent("homeItems.legacy.json"))

        cache.clearAll()

        #expect(fileNames(in: directory).isEmpty)
    }

    // MARK: - Migration

    /// Files from before the scoping are unreachable the moment readers ask for scoped keys, so the
    /// sweep deletes what no longer parses rather than leaving a directory that only grows. The
    /// format marker is what makes that exact: a legacy key holding two dots also splits into
    /// enough segments, and would otherwise be mistaken for an identity that never existed.
    @Test func theSweepDropsEveryPreScopingFile() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        cache.setHomeFilterItems([item("keep")], filterKey: "k", identity: Self.a1)
        for legacy in [
            "homeItems.home-genre-Action.json",
            "homeItems.home-genre-Dr.%20Who%20Jr.%20Show.json",
            "smart.337-DE.json",
            "catalog.movieGenre-28.json",
        ] {
            try? Data("{}".utf8).write(to: directory.appendingPathComponent(legacy))
        }

        cache.migrateAndTrim(keeping: nil)

        #expect(fileNames(in: directory) == ["v2.homeItems.serverA.user1.k.json"])
        #expect(cache.homeFilterItems(filterKey: "k", identity: Self.a1)?.map(\.id) == ["keep"])
    }

    // MARK: - Identity limit

    /// Without the bulk wipes the directory grows per identity, so the trim is the only bound left.
    @Test func theTrimKeepsTheMostRecentlyWrittenIdentities() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overflow = FilterCache.identityLimit + 2
        var identities: [CacheIdentity] = []
        for index in 0..<overflow {
            let identity = CacheIdentity(serverID: "server\(index)", userID: "user\(index)")
            identities.append(identity)
            cache.setHomeFilterItems([item("x")], filterKey: "k", identity: identity)
            // Oldest first: index 0 is the least recently written.
            stamp(identity, in: directory, to: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }

        cache.migrateAndTrim(keeping: nil)

        let survivors = identities.filter { cache.homeFilterItems(filterKey: "k", identity: $0) != nil }
        #expect(survivors.count == FilterCache.identityLimit)
        #expect(!survivors.contains(identities[0]))
        #expect(!survivors.contains(identities[1]))
        #expect(survivors.contains(identities[overflow - 1]))
    }

    /// The identity being switched TO is about to be read, and its files can be older than the ones
    /// the session is leaving behind. Trimming it would hand it the loading grid this whole change
    /// exists to remove.
    @Test func theTrimNeverDropsTheIdentityBeingSwitchedTo() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overflow = FilterCache.identityLimit + 2
        var identities: [CacheIdentity] = []
        for index in 0..<overflow {
            let identity = CacheIdentity(serverID: "server\(index)", userID: "user\(index)")
            identities.append(identity)
            cache.setHomeFilterItems([item("x")], filterKey: "k", identity: identity)
            stamp(identity, in: directory, to: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }

        let oldest = identities[0]
        cache.migrateAndTrim(keeping: oldest)

        let survivors = identities.filter { cache.homeFilterItems(filterKey: "k", identity: $0) != nil }
        #expect(survivors.contains(oldest))
        #expect(survivors.count == FilterCache.identityLimit)
    }

    /// Below the limit the trim is a no-op, so an ordinary two-server install never loses an entry
    /// to it.
    @Test func theTrimLeavesADirectoryUnderTheLimitAlone() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        for identity in [Self.a1, Self.a2, Self.b1] {
            cache.setHomeFilterItems([item("x")], filterKey: "k", identity: identity)
        }

        cache.migrateAndTrim(keeping: Self.b1)

        #expect(fileNames(in: directory).count == 3)
    }
}
