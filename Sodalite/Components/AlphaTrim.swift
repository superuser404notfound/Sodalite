import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The visible mark inside a title logo, without the transparent canvas around it (Sodalite#192).
///
/// Scraped logo PNGs carry a margin that differs from file to file, and Jellyfin stopped cropping it
/// in 10.8 (`cropWhitespace` removed in jellyfin#4988, the parameter dropped in 10.9). Left in, the
/// margin is what `ContentLogoSizing` measures and what the bottom-leading slot puts on the edge, so
/// two logos at the same budget draw at different sizes and different insets.
///
/// Strictly alpha == 0 counts as empty. No colour rule and no threshold: a soft glow baked into a
/// logo is part of the mark.
enum AlphaTrim {

    /// The bounding box of every pixel with any alpha, in the image's own pixel space (top-left
    /// origin, which is what `CGImage.cropping(to:)` reads). Nil when there is nothing to trim: an
    /// image without an alpha channel, one whose ink already reaches all four edges, and one with no
    /// ink at all, which keeps the original rather than cropping to nothing.
    nonisolated static func inkBounds(of image: CGImage) -> CGRect? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
              ),
              let buffer = context.data
        else { return nil }

        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let stride = context.bytesPerRow
        let alpha = buffer.bindMemory(to: UInt8.self, capacity: stride * height)
        func rowHasInk(_ y: Int) -> Bool {
            let row = alpha + y * stride
            for x in 0..<width where row[x] != 0 { return true }
            return false
        }
        func columnHasInk(_ x: Int, rows: ClosedRange<Int>) -> Bool {
            for y in rows where alpha[y * stride + x] != 0 { return true }
            return false
        }

        // Inward from each edge, so a logo with a thin margin touches only that margin.
        guard let top = (0..<height).first(where: rowHasInk) else { return nil }
        let bottom = (top..<height).reversed().first(where: rowHasInk) ?? top
        let rows = top...bottom
        let left = (0..<width).first { columnHasInk($0, rows: rows) } ?? 0
        let right = (left..<width).reversed().first { columnHasInk($0, rows: rows) } ?? left

        let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return bounds.size == CGSize(width: width, height: height) ? nil : bounds
    }
}

nonisolated extension PlatformImage {
    /// The same image cropped to `AlphaTrim.inkBounds`, at the same scale, or `self` when there is
    /// nothing to trim. The crop shares the decoded image's backing store.
    func trimmingTransparentMargin() -> PlatformImage {
        #if canImport(UIKit)
        guard imageOrientation == .up else { return self }
        #endif
        guard let cgImage,
              let bounds = AlphaTrim.inkBounds(of: cgImage),
              let cropped = cgImage.cropping(to: bounds)
        else { return self }
        let scale = pixelScale
        return .wrapping(cropped, size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
    }
}
