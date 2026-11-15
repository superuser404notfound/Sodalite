import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Jellyfin trickplay sprites for one playback session.
///
/// The bytes of every sprite are fetched in the background a few seconds into playback, nearest the
/// playhead first, so a scrub only decodes. A sprite is downloaded once and decoded once, and a scrub
/// that moves on does not cancel either: the old behaviour cancelled the download with every move of
/// the knob, so a fast swipe never finished one and the preview stayed empty until the finger rested
/// (Sodalite#212).
@MainActor
final class TrickplayTileStore {
    typealias Fetch = @Sendable (URL) async -> Data?

    /// Compressed sprites kept for the session. A 320 px sprite is some 3200 x 1800 and 300 to 800 KB,
    /// so this holds a feature film's whole set; past it, the rest is fetched when a scrub reaches it.
    nonisolated static let byteBudget = 24_000_000

    private let tileSet: TrickplayTileSet
    private let tileURL: (Int) -> URL?
    private let fetch: Fetch
    private var bytes: [Int: Data] = [:]
    private var storedBytes = 0
    private var downloads: [Int: Task<Data?, Never>] = [:]
    private var decodes: [Int: Task<PlatformImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var isClosed = false

    init(tileSet: TrickplayTileSet, tileURL: @escaping (Int) -> URL?, fetch: @escaping Fetch = TrickplayTileStore.download) {
        self.tileSet = tileSet
        self.tileURL = tileURL
        self.fetch = fetch
    }

    /// The thumbnail at `seconds`, cropped out of its sprite. Nil when the sprite cannot be had.
    func thumbnail(seconds: Double) async -> CGImage? {
        guard let placement = tileSet.tile(forSeconds: seconds),
              let url = tileURL(placement.tileIndex) else { return nil }
        let sheet: PlatformImage
        if let cached = ImageCache.shared.image(for: url) {
            sheet = cached
        } else {
            guard let decoded = await self.sheet(placement.tileIndex, url: url) else { return nil }
            sheet = decoded
        }
        return Self.crop(sheet, to: placement.crop)
    }

    /// Fetches every sprite's bytes after `delay`, nearest `position()` first, one at a time so it
    /// stays out of the way of the stream beside it. Stops at `byteBudget`.
    func prefetch(after delay: Duration = .seconds(3), position: @escaping () -> Double) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            for index in self.tileSet.tileOrder(nearestTo: position()) {
                guard !Task.isCancelled, !self.isClosed, self.storedBytes < Self.byteBudget else { return }
                guard let url = self.tileURL(index) else { continue }
                _ = await self.data(index, url: url)
            }
        }
    }

    /// Session teardown: stops the prefetch and every download, and drops the bytes.
    func close() {
        isClosed = true
        prefetchTask?.cancel()
        prefetchTask = nil
        downloads.values.forEach { $0.cancel() }
        downloads.removeAll()
        decodes.removeAll()
        bytes.removeAll()
        storedBytes = 0
    }

    var storedTileCount: Int { bytes.count }

    private func sheet(_ index: Int, url: URL) async -> PlatformImage? {
        if let running = decodes[index] { return await running.value }
        let task = Task { [weak self] () -> PlatformImage? in
            guard let self, let data = await self.data(index, url: url) else { return nil }
            guard let image = await Self.decode(data) else { return nil }
            ImageCache.shared.store(image, for: url)
            return image
        }
        decodes[index] = task
        let image = await task.value
        decodes[index] = nil
        return image
    }

    private func data(_ index: Int, url: URL) async -> Data? {
        if let stored = bytes[index] { return stored }
        if let running = downloads[index] { return await running.value }
        let fetch = fetch
        let task = Task { await fetch(url) }
        downloads[index] = task
        let data = await task.value
        downloads[index] = nil
        if let data, !isClosed, bytes[index] == nil, storedBytes + data.count <= Self.byteBudget {
            bytes[index] = data
            storedBytes += data.count
        }
        return data
    }

    @concurrent nonisolated private static func decode(_ data: Data) async -> PlatformImage? {
        guard let image = PlatformImage(data: data) else { return nil }
        return image.preparedForDisplay() ?? image
    }

    nonisolated private static func crop(_ sheet: PlatformImage, to rect: CGRect) -> CGImage? {
        guard let cg = sheet.cgImage,
              rect.maxX <= CGFloat(cg.width), rect.maxY <= CGFloat(cg.height) else { return nil }
        return cg.cropping(to: rect)
    }

    @concurrent nonisolated static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard case .whole(let data) = await ImageFetch.load(request) else { return nil }
        return data
    }
}
