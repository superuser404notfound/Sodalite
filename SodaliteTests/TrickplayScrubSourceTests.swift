import Testing
import CoreGraphics
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