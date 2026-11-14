import Testing
import Foundation
@testable import Sodalite

/// The shared cache writes off the caller's thread, because Home stores its rows from MainActor and
/// the encode plus the atomic rename showed up in a trace of the first tab switches. Nothing a
/// caller can observe may change with it.
struct FilterCacheAsyncWriteTests {

    private static let a1 = CacheIdentity(serverID: "serverA", userID: "user1")

    private func makeCache() -> (cache: FilterCache, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilterCacheAsync-\(UUID().uuidString)", isDirectory: true)
        return (FilterCache(directory: directory, writesAsynchronously: true), directory)
    }

    private func item(_ id: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: id)
    }

    @Test func aReadRightAfterAWriteSeesTheNewValue() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FilterCacheKey.Home.genre(name: "Action")

        cache.setHomeFilterItems([item("old")], filterKey: key, identity: Self.a1)
        cache.setHomeFilterItems([item("new")], filterKey: key, identity: Self.a1)

        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1)?.map(\.id) == ["new"])
    }

    @Test func theLastWriteIsTheOneOnDisk() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FilterCacheKey.Home.genre(name: "Action")

        for index in 0..<20 {
            cache.setHomeFilterItems([item("v\(index)")], filterKey: key, identity: Self.a1)
        }
        cache.flush()

        let fresh = FilterCache(directory: directory)
        #expect(fresh.homeFilterItems(filterKey: key, identity: Self.a1)?.map(\.id) == ["v19"])
    }

    /// A queued write must not bring an evicted profile back.
    @Test func anEvictionDropsWhatWasStillQueued() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = FilterCacheKey.Home.genre(name: "Action")

        cache.setHomeFilterItems([item("a")], filterKey: key, identity: Self.a1)
        cache.evict(identity: Self.a1)

        #expect(cache.homeFilterItems(filterKey: key, identity: Self.a1) == nil)
        cache.flush()
        #expect(FilterCache(directory: directory).homeFilterItems(filterKey: key, identity: Self.a1) == nil)
    }
}
