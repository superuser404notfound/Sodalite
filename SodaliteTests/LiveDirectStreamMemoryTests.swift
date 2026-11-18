import Foundation
import Testing
@testable import Sodalite

@Suite("Live direct-stream memory")
@MainActor
struct LiveDirectStreamMemoryTests {

    private static let user = "user-1"
    private static let channel = "channel-1"
    private static let upstream = URL(string: "https://provider.example/live/u/p/42.m3u8")!

    private func makeMemory(
        _ keychain: KeychainServiceProtocol = InMemoryKeychain()
    ) -> LiveDirectStreamMemory {
        LiveDirectStreamMemory(keychain: keychain)
    }

    @Test("a remembered upstream comes back for the same user and channel")
    func remembersUpstream() {
        let memory = makeMemory()
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel)
        let read = memory.upstream(userID: Self.user, channelID: Self.channel)
        #expect(read == Self.upstream)
    }

    @Test("an unknown channel has no upstream")
    func unknownChannelIsEmpty() {
        let memory = makeMemory()
        let read = memory.upstream(userID: Self.user, channelID: "never-tuned")
        #expect(read == nil)
    }

    @Test("another profile does not see this profile's upstream")
    func scopedByUser() {
        let memory = makeMemory()
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel)
        let read = memory.upstream(userID: "user-2", channelID: Self.channel)
        #expect(read == nil)
    }

    @Test("an entry past maxAge is not served and is dropped")
    func expiredEntryIsDropped() {
        let keychain = InMemoryKeychain()
        let memory = makeMemory(keychain)
        let storedAt = Date(timeIntervalSince1970: 1_000_000)
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel, now: storedAt)

        let justInside = storedAt.addingTimeInterval(LiveDirectStreamMemory.maxAge - 60)
        let insideRead = memory.upstream(userID: Self.user, channelID: Self.channel, now: justInside)
        #expect(insideRead == Self.upstream)

        let past = storedAt.addingTimeInterval(LiveDirectStreamMemory.maxAge + 60)
        let expiredRead = memory.upstream(userID: Self.user, channelID: Self.channel, now: past)
        #expect(expiredRead == nil)

        // Dropped, not merely hidden: a later read at the stored time finds nothing either.
        let reread = memory.upstream(userID: Self.user, channelID: Self.channel, now: storedAt)
        #expect(reread == nil)
    }

    @Test("re-recording refreshes the age so a channel in daily use never expires")
    func rememberRefreshesAge() {
        let memory = makeMemory()
        let first = Date(timeIntervalSince1970: 1_000_000)
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel, now: first)

        let later = first.addingTimeInterval(LiveDirectStreamMemory.maxAge - 60)
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel, now: later)

        let wouldHaveExpired = first.addingTimeInterval(LiveDirectStreamMemory.maxAge + 60)
        let read = memory.upstream(userID: Self.user, channelID: Self.channel, now: wouldHaveExpired)
        #expect(read == Self.upstream)
    }

    @Test("forget drops the entry so the next tune renegotiates")
    func forgetDropsEntry() {
        let memory = makeMemory()
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel)
        memory.forget(userID: Self.user, channelID: Self.channel)
        let read = memory.upstream(userID: Self.user, channelID: Self.channel)
        #expect(read == nil)
    }

    @Test("forgetAll clears one profile and leaves the others alone")
    func forgetAllIsScopedToTheProfile() {
        let memory = makeMemory()
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel)
        memory.remember(Self.upstream, userID: Self.user, channelID: "channel-2")
        memory.remember(Self.upstream, userID: "user-2", channelID: Self.channel)

        memory.forgetAll(userID: Self.user)

        let gone = memory.upstream(userID: Self.user, channelID: Self.channel)
        #expect(gone == nil)
        let alsoGone = memory.upstream(userID: Self.user, channelID: "channel-2")
        #expect(alsoGone == nil)
        let kept = memory.upstream(userID: "user-2", channelID: Self.channel)
        #expect(kept == Self.upstream)
    }

    @Test("entries survive a new instance over the same keychain")
    func persistsAcrossInstances() {
        let keychain = InMemoryKeychain()
        makeMemory(keychain).remember(Self.upstream, userID: Self.user, channelID: Self.channel)
        let reloaded = makeMemory(keychain)
        let read = reloaded.upstream(userID: Self.user, channelID: Self.channel)
        #expect(read == Self.upstream)
    }

    @Test("a stored value that no longer parses as a URL is dropped")
    func unparsableEntryIsDropped() throws {
        let keychain = InMemoryKeychain()
        let key = LiveDirectStreamMemory.scopeKey(userID: Self.user, channelID: Self.channel)
        let blob = [key: LiveDirectStreamMemory.Entry(url: "", updatedAt: Date())]
        try keychain.save(JSONEncoder().encode(blob), for: KeychainKeys.liveDirectStreams)

        let memory = makeMemory(keychain)
        let read = memory.upstream(userID: Self.user, channelID: Self.channel)
        #expect(read == nil)
    }

    @Test("eviction keeps the most recently used entries")
    func evictionKeepsRecent() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let overflow = LiveDirectStreamMemory.maxEntries + 50
        var entries: [String: LiveDirectStreamMemory.Entry] = [:]
        for index in 0..<overflow {
            entries["channel-\(index)"] = LiveDirectStreamMemory.Entry(
                url: "https://provider.example/\(index).m3u8",
                updatedAt: base.addingTimeInterval(Double(index))
            )
        }

        let capped = LiveDirectStreamMemory.capped(entries)
        let count = capped.count
        #expect(count == LiveDirectStreamMemory.maxEntries)
        // Oldest 50 gone, newest kept.
        let oldest = capped["channel-0"]
        #expect(oldest == nil)
        let newest = capped["channel-\(overflow - 1)"]
        #expect(newest != nil)
    }

    @Test("a set at the cap is left untouched")
    func atCapIsUntouched() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var entries: [String: LiveDirectStreamMemory.Entry] = [:]
        for index in 0..<LiveDirectStreamMemory.maxEntries {
            entries["channel-\(index)"] = LiveDirectStreamMemory.Entry(
                url: "https://provider.example/\(index).m3u8",
                updatedAt: base
            )
        }
        let capped = LiveDirectStreamMemory.capped(entries)
        let count = capped.count
        #expect(count == LiveDirectStreamMemory.maxEntries)
    }

    @Test("re-recording an unchanged upstream inside a day does not rewrite the keychain")
    func unchangedUpstreamSkipsTheWrite() {
        let keychain = CountingKeychain()
        let memory = makeMemory(keychain)
        let t = Date(timeIntervalSince1970: 1_000_000)
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel, now: t)
        #expect(keychain.saves == 1)
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel, now: t.addingTimeInterval(3600))
        #expect(keychain.saves == 1)
        memory.remember(Self.upstream, userID: Self.user, channelID: Self.channel,
                        now: t.addingTimeInterval(LiveDirectStreamMemory.refreshInterval + 1))
        #expect(keychain.saves == 2)
        let moved = URL(string: "https://provider.example/live/u/p/43.m3u8")!
        memory.remember(moved, userID: Self.user, channelID: Self.channel, now: t.addingTimeInterval(7200))
        #expect(keychain.saves == 3)
    }
}

nonisolated private final class CountingKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private let inner = InMemoryKeychain()
    private let lock = NSLock()
    private var _saves = 0
    var saves: Int { lock.withLock { _saves } }

    func save(_ data: Data, for key: String) throws {
        lock.withLock { _saves += 1 }
        try inner.save(data, for: key)
    }
    func save(_ string: String, for key: String) throws { try save(Data(string.utf8), for: key) }
    func loadData(for key: String) throws -> Data? { try inner.loadData(for: key) }
    func loadString(for key: String) throws -> String? { try inner.loadString(for: key) }
    func delete(for key: String) throws { try inner.delete(for: key) }
    func deleteAll() throws { try inner.deleteAll() }
}
