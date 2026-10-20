import Testing
import Foundation
import UIKit
@testable import Sodalite

/// Sodalite#192. Scraped logo PNGs carry a transparent margin that differs from file to file, and
/// Jellyfin stopped cropping it in 10.8, so the budget and the bottom-leading slot measured the
/// canvas instead of the mark.
struct AlphaTrimTests {

    /// A canvas of `canvas` pixels with `ink` filled at `alpha`, round-tripped through PNG bytes so
    /// the image is the one `UIImage(data:)` hands the loader, not the renderer's own.
    private func logo(
        canvas: CGSize = CGSize(width: 400, height: 200),
        ink: CGRect,
        alpha: CGFloat = 1,
        opaque: Bool = false
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        let drawn = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor(white: 1, alpha: alpha).setFill()
            context.fill(ink)
        }
        return UIImage(data: drawn.pngData()!)!
    }

    @Test("an uneven margin is cut to the ink, in top-left pixel space")
    func unevenMargin() throws {
        let ink = CGRect(x: 30, y: 10, width: 300, height: 120)
        let image = logo(ink: ink)
        #expect(AlphaTrim.inkBounds(of: try #require(image.cgImage)) == ink)

        let trimmed = image.trimmingTransparentMargin()
        #expect(trimmed.size == ink.size)
    }

    @Test("the faintest ink is still ink: strictly alpha == 0 is margin")
    func faintInkCounts() throws {
        let ink = CGRect(x: 50, y: 40, width: 100, height: 60)
        let image = logo(ink: ink, alpha: 2.0 / 255.0)
        #expect(AlphaTrim.inkBounds(of: try #require(image.cgImage)) == ink)
    }

    @Test("ink that already reaches every edge leaves the image as it is")
    func noMargin() {
        let image = logo(ink: CGRect(x: 0, y: 0, width: 400, height: 200))
        #expect(image.trimmingTransparentMargin() === image)
    }

    @Test("a canvas with no ink at all is kept, not cropped to nothing")
    func emptyCanvas() {
        let image = logo(ink: .zero)
        #expect(image.trimmingTransparentMargin() === image)
    }

    @Test("an image without alpha is skipped at no cost")
    func jpegIsSkipped() throws {
        let opaque = logo(ink: CGRect(x: 30, y: 10, width: 300, height: 120), opaque: true)
        let bytes = try #require(opaque.jpegData(compressionQuality: 0.9))
        let jpeg = try #require(UIImage(data: bytes))
        #expect(AlphaTrim.inkBounds(of: try #require(jpeg.cgImage)) == nil)
        #expect(jpeg.trimmingTransparentMargin() === jpeg)
    }

    @Test("the crop keeps the source scale, so the point size is the ink's")
    func keepsScale() throws {
        let source = logo(ink: CGRect(x: 20, y: 20, width: 200, height: 100))
        let atTwo = UIImage(cgImage: try #require(source.cgImage), scale: 2, orientation: .up)
        let trimmed = atTwo.trimmingTransparentMargin()
        #expect(trimmed.scale == 2)
        #expect(trimmed.size == CGSize(width: 100, height: 50))
    }

    @Test("the trimmed copy is cached under its own key, the request URL is untouched")
    func trimmedKey() throws {
        let url = try #require(URL(string: "https://jf.example/Items/abc/Images/Logo?maxWidth=800"))
        let key = ImageCache.trimmedKey(for: url)
        #expect(key != url)
        #expect(key.absoluteString.hasPrefix(url.absoluteString))
        #expect(ImageCache.trimmedKey(for: url) == key)
    }
}
