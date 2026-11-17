import Foundation
import Testing
@testable import Sodalite

/// BRW-203: overlapping `ImageCache.prefetch` runs must not load the same URL twice.
struct PrefetchInFlightTests {
    @Test func aSecondClaimOfTheSameUrlsGetsNothing() throws {
        let urls = try (0..<3).map { try #require(URL(string: "https://img.example/prefetch-claim-\($0).jpg")) }
        let first = PrefetchInFlight.claim(urls)
        let second = PrefetchInFlight.claim(urls)
        #expect(first == urls)
        #expect(second.isEmpty)
        PrefetchInFlight.release(first)
        #expect(PrefetchInFlight.claim(urls) == urls)
        PrefetchInFlight.release(urls)
    }

    @Test func repeatsWithinOneClaimCountOnce() throws {
        let url = try #require(URL(string: "https://img.example/prefetch-claim-dup.jpg"))
        let claimed = PrefetchInFlight.claim([url, url])
        #expect(claimed == [url])
        PrefetchInFlight.release(claimed)
    }

    /// R-BROWSE-1: a run replaced after waiting for the cancelled one loads every URL, once.
    @Test func aReplacedRunLoadsEveryUrlOnce() async throws {
        let urls = try (0..<4).map { try #require(URL(string: "https://img.example/prefetch-replace-\($0).jpg")) }
        let auth = ImageAuth(bases: [])
        let started = LoadLog()
        let first = Task {
            await ImageCache.prefetch(urls, auth: auth) { url, _ in
                started.add(url)
                do { try await Task.sleep(for: .seconds(30)) } catch { return false }
                return true
            }
        }
        while started.count < min(urls.count, ImageFetch.connectionsPerHost / 2) { try await Task.sleep(for: .milliseconds(10)) }
        first.cancel()
        _ = await first.value
        let second = LoadLog()
        let warmed = await ImageCache.prefetch(urls, auth: auth) { url, _ in second.add(url); return true }
        #expect(warmed == 4)
        #expect(second.urls.sorted { $0.absoluteString < $1.absoluteString } == urls)
    }
}

nonisolated private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [URL] = []
    func add(_ url: URL) { lock.withLock { loaded.append(url) } }
    var count: Int { lock.withLock { loaded.count } }
    var urls: [URL] { lock.withLock { loaded } }
}
