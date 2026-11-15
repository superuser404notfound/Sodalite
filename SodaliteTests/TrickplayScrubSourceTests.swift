import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import Sodalite

struct TrickplayScrubSourceTests {
    private func tileSet() -> TrickplayTileSet? {
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10,
                                 thumbnailCount: 100, interval: 10000, bandwidth: nil)
        return TrickplayTileSet(trickplay: ["s": ["320": info]], mediaSourceID: "s", targetWidth: 320)
    }

    @Test("server source only when preferred AND tiles exist")
    func decision() {
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: true, tileSet: tileSet()) == true)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: true, tileSet: nil) == false)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: false, tileSet: tileSet()) == false)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: false, tileSet: nil) == false)
    }

    @Test("a disc folder takes the tiles without the preference, it has no extractor (#185)")
    func discFolderPrefersTiles() {
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: false, tileSet: tileSet(),
                                                         isDiscFolder: true) == true)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: false, tileSet: nil,
                                                         isDiscFolder: true) == false)
    }

    @Test("the tile URL carries the token as ApiKey too, Jellyfin 12 ignores api_key (#234)")
    @MainActor
    func tileURLUsesApiKey() throws {
        let client = JellyfinClient()
        client.baseURL = URL(string: "https://jf.example/jellyfin")
        client.accessToken = "tok"
        let url = try #require(JellyfinPlaybackService(client: client)
            .buildTrickplayTileURL(itemID: "abc", width: 320, tileIndex: 4))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/jellyfin/Videos/abc/Trickplay/320/4.jpg")
        #expect(items == [URLQueryItem(name: "api_key", value: "tok"), URLQueryItem(name: "ApiKey", value: "tok")])
    }
}

@MainActor
struct ScrubPreviewResolutionTests {

    private func dummyImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test("cache hit returns the cache image and is consulted once")
    func cacheHit() async {
        let provider = ScrubPreviewProvider()
        let img = dummyImage()
        var cacheCalls = 0
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in cacheCalls += 1; return img },
                           enabled: true)
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result != nil)
        #expect(cacheCalls == 1)
    }

    @Test("cache miss with no extractor yields nil")
    func cacheMissNoExtractor() async {
        let provider = ScrubPreviewProvider()
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in nil },
                           enabled: true)
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result == nil)
    }

    @Test("server source takes precedence and is used")
    func serverSource() async {
        let provider = ScrubPreviewProvider()
        let img = dummyImage()
        var serverCalls = 0
        provider.configure(serverThumbnail: { _ in serverCalls += 1; return img },
                           enabled: true)
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result != nil)
        #expect(serverCalls == 1)
    }

    /// Sodalite#151 round 2, as the premise rather than the symptom: the tiers are asked per
    /// position, so one session answers with a frame at one point on the track and with nothing at
    /// another. The cache tier only holds what has been played or read ahead, so the same position
    /// changes its answer as the session goes on. That is why the seek readout cannot be drawn
    /// beside a clock whose size and place this decides.
    @Test("a frame is a property of the position, not of the session")
    func availabilityIsPerPosition() async {
        let provider = ScrubPreviewProvider()
        let img = dummyImage()
        provider.configure(extractor: nil,
                           cacheThumbnail: { seconds, _ in seconds < 60 ? img : nil },
                           enabled: true)
        let resident = await provider.resolveThumbnail(seconds: 10)
        let beyond = await provider.resolveThumbnail(seconds: 600)
        #expect(resident != nil)
        #expect(beyond == nil)
    }

    @Test("reset clears the cache source")
    func resetClearsCache() async {
        let provider = ScrubPreviewProvider()
        var cacheCalls = 0
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in cacheCalls += 1; return self.dummyImage() },
                           enabled: true)
        provider.reset()
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result == nil)
        #expect(cacheCalls == 0)
    }

    /// Waits up to two seconds for `condition`, so a timing test fails on its claim, not on a slow runner.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("a resting knob replaces the coarse keyframe with the exact frame")
    func restRefines() async {
        let provider = ScrubPreviewProvider()
        let coarse = dummyImage(), exact = dummyImage()
        var refinedAt: [Double] = []
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in coarse },
                           refinedThumbnail: { seconds, _, _ in refinedAt.append(seconds); return exact },
                           enabled: true)
        provider.refineDelay = .milliseconds(20)
        provider.update(fraction: 0.5, durationSeconds: 100)
        #expect(await eventually { provider.previewImage === exact })
        #expect(refinedAt == [50])
    }

    @Test("a knob that keeps moving never pays for the exact frame")
    func movingSkipsRefine() async {
        let provider = ScrubPreviewProvider()
        let coarse = dummyImage()
        var refineCalls = 0
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in coarse },
                           refinedThumbnail: { _, _, _ in refineCalls += 1; return nil },
                           enabled: true)
        provider.refineDelay = .seconds(10)
        provider.update(fraction: 0.2, durationSeconds: 100)
        #expect(await eventually { provider.previewImage === coarse })
        provider.update(fraction: 0.3, durationSeconds: 100)
        provider.clear()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(refineCalls == 0)
        #expect(provider.previewImage === coarse)
    }

    @Test("a position the cache does not hold is not refined, and a refine miss keeps the keyframe")
    func refineNeedsCoarseAndKeepsItOnMiss() async {
        let provider = ScrubPreviewProvider()
        let coarse = dummyImage()
        var refined: [Double] = []
        provider.configure(extractor: nil,
                           cacheThumbnail: { seconds, _ in seconds < 60 ? coarse : nil },
                           refinedThumbnail: { seconds, _, _ in refined.append(seconds); return nil },
                           enabled: true)
        provider.refineDelay = .milliseconds(20)
        provider.update(fraction: 0.75, durationSeconds: 100)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(refined.isEmpty)
        provider.update(fraction: 0.25, durationSeconds: 100)
        #expect(await eventually { refined == [25] })
        #expect(provider.previewImage === coarse)
    }
}
/// Sodalite#212 round 4: a fast swipe over server trickplay showed nothing until the finger rested.
@MainActor
struct TrickplayTileStoreTests {
    private let info = TrickplayInfo(width: 2, height: 2, tileWidth: 2, tileHeight: 2,
                                     thumbnailCount: 12, interval: 1000, bandwidth: nil)

    /// A 4 x 4 JPEG, the sprite of a 2 x 2 grid of 2 px thumbnails.
    private static let sprite: Data = {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }()

    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func store(fetches: Counter, delay: Duration = .zero) throws -> TrickplayTileStore {
        let tiles = try #require(TrickplayTileSet(trickplay: ["s": ["2": info]], mediaSourceID: "s", targetWidth: 2))
        let run = UUID().uuidString
        let sprite = Self.sprite
        return TrickplayTileStore(tileSet: tiles,
                                  tileURL: { URL(string: "https://jf.test/\(run)/\($0).jpg") },
                                  fetch: { _ in
                                      fetches.bump()
                                      if delay > .zero { try? await Task.sleep(for: delay) }
                                      return sprite
                                  })
    }

    @Test("a sprite is downloaded once however many positions ask for it")
    func oneDownloadPerSprite() async throws {
        let fetches = Counter()
        let tiles = try store(fetches: fetches, delay: .milliseconds(50))
        async let a = tiles.thumbnail(seconds: 0)
        async let b = tiles.thumbnail(seconds: 1)
        async let c = tiles.thumbnail(seconds: 3)
        let images = await [a, b, c]
        #expect(images.allSatisfy { $0?.width == 2 })
        #expect(fetches.count == 1)
    }

    @Test("a scrub that moves on does not cancel the sprite's download")
    func cancelledAskStillLands() async throws {
        let fetches = Counter()
        let tiles = try store(fetches: fetches, delay: .milliseconds(50))
        let first = Task { await tiles.thumbnail(seconds: 0) }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        _ = await first.value
        #expect(await tiles.thumbnail(seconds: 2) != nil)
        #expect(fetches.count == 1)
    }

    @Test("the prefetch fetches every sprite once and keeps the bytes")
    func prefetchAll() async throws {
        let fetches = Counter()
        let tiles = try store(fetches: fetches)
        tiles.prefetch(after: .zero) { 5 }
        for _ in 0..<200 where tiles.storedTileCount < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tiles.storedTileCount == 3)
        #expect(fetches.count == 3)
        _ = await tiles.thumbnail(seconds: 9)
        #expect(fetches.count == 3)
    }

    @Test("close stops the prefetch and drops the bytes")
    func closeStops() async throws {
        let fetches = Counter()
        let tiles = try store(fetches: fetches)
        tiles.prefetch(after: .milliseconds(50)) { 0 }
        tiles.close()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fetches.count == 0)
        #expect(tiles.storedTileCount == 0)
    }

    @Test("server trickplay publishes without waiting for the knob to rest")
    func serverIsNotDebounced() async {
        let provider = ScrubPreviewProvider()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        var asked: [Double] = []
        provider.configure(serverThumbnail: { seconds in asked.append(seconds); return img }, enabled: true)
        // A swipe: a new position every 16 ms, faster than the 60 ms debounce the other sources keep.
        for step in 0..<10 {
            provider.update(fraction: Float(step) / 10, durationSeconds: 100)
            try? await Task.sleep(for: .milliseconds(16))
        }
        #expect(asked.count >= 5)
        #expect(provider.previewImage != nil)
    }
}
