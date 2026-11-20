import Foundation
import CoreGraphics

/// Resolves a scrub time to a Jellyfin trickplay tile index + the crop rect of the thumbnail
/// inside that sprite. Pure value type, no I/O. Built once per session from the item's manifest.
struct TrickplayTileSet: Equatable, Sendable {
    let width: Int
    let info: TrickplayInfo

    /// Picks the rendition whose width is closest to `targetWidth`. nil when the item has no
    /// trickplay for `mediaSourceID` (or any source as a fallback) or no parseable width keys.
    init?(trickplay: [String: [String: TrickplayInfo]]?, mediaSourceID: String?, targetWidth: Int) {
        guard let trickplay, !trickplay.isEmpty else { return nil }
        let renditions = mediaSourceID.flatMap { trickplay[$0] } ?? trickplay.first?.value
        guard let renditions, !renditions.isEmpty else { return nil }
        let pick = renditions
            .compactMap { key, value -> (Int, TrickplayInfo)? in
                guard let w = Int(key), w > 0 else { return nil }
                return (w, value)
            }
            .min { abs($0.0 - targetWidth) < abs($1.0 - targetWidth) }
        guard let pick else { return nil }
        self.width = pick.0
        self.info = pick.1
    }

    /// Sprites the manifest spans; 0 when the manifest is unusable.
    var tileCount: Int {
        let perTile = info.tileWidth * info.tileHeight
        guard perTile > 0, info.thumbnailCount > 0 else { return 0 }
        return (info.thumbnailCount + perTile - 1) / perTile
    }

    /// Every sprite once, the one holding `seconds` first, then outward with the later one ahead
    /// of the earlier at each distance: a scrub usually starts at the playhead and goes forward.
    func tileOrder(nearestTo seconds: Double) -> [Int] {
        let count = tileCount
        guard count > 0 else { return [] }
        let center = tile(forSeconds: seconds)?.tileIndex ?? 0
        var order = [center]
        var distance = 1
        while order.count < count {
            if center + distance < count { order.append(center + distance) }
            if center - distance >= 0 { order.append(center - distance) }
            distance += 1
        }
        return order
    }

    /// (tileIndex, crop). Thumbnail index = floor(ms / interval), clamped to thumbnailCount-1.
    /// A tile holds tileWidth x tileHeight thumbnails laid out row-major.
    func tile(forSeconds seconds: Double) -> (tileIndex: Int, crop: CGRect)? {
        guard info.interval > 0, info.tileWidth > 0, info.tileHeight > 0,
              info.width > 0, info.height > 0, info.thumbnailCount > 0 else { return nil }
        let ms = max(0, seconds) * 1000
        let rawThumb = Int(ms / Double(info.interval))
        let thumb = min(rawThumb, info.thumbnailCount - 1)
        let perTile = info.tileWidth * info.tileHeight
        let tileIndex = thumb / perTile
        let within = thumb % perTile
        let col = within % info.tileWidth
        let row = within / info.tileWidth
        let crop = CGRect(x: col * info.width, y: row * info.height,
                          width: info.width, height: info.height)
        return (tileIndex, crop)
    }
}
