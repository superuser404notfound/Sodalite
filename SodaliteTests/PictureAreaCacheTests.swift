import Testing
import Foundation
import CoreGraphics
import AetherEngine
@testable import Sodalite

/// Sodalite#118: a title's picture area is remembered, so a Resume zooms before the first frame.
struct PictureAreaCacheTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("picture-areas-\(UUID().uuidString).json")
    }

    private let scope = PictureArea(rect: CGRect(x: 0, y: 0.128, width: 1, height: 0.744), snappedRatio: 2.39)

    @Test func roundTrip() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        PictureAreaCache(fileURL: file).store(scope, for: "s|i|m")
        #expect(PictureAreaCache(fileURL: file).area(for: "s|i|m") == scope)
    }

    @Test func evictsOldest() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = PictureAreaCache(fileURL: file, capacity: 3)
        for i in 0..<4 { cache.store(scope, for: "k\(i)") }
        #expect(cache.area(for: "k0") == nil)
        #expect(cache.area(for: "k3") == scope)
        #expect(PictureAreaCache(fileURL: file, capacity: 3).area(for: "k1") == scope)
    }

    @Test func separateKeysPerMediaSource() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = PictureAreaCache(fileURL: file)
        cache.store(scope, for: PictureAreaCache.key(serverID: "s", itemID: "i", mediaSourceID: "a"))
        #expect(cache.area(for: PictureAreaCache.key(serverID: "s", itemID: "i", mediaSourceID: "b")) == nil)
        #expect(cache.area(for: PictureAreaCache.key(serverID: "s", itemID: "i", mediaSourceID: "a")) == scope)
    }

    @Test func asynchronousWritesLandAfterFlush() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = PictureAreaCache(fileURL: file, writesAsynchronously: true)
        cache.store(scope, for: "k")
        #expect(cache.area(for: "k") == scope)
        cache.flush()
        #expect(PictureAreaCache(fileURL: file).area(for: "k") == scope)
    }
}
