import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Sodalite

/// The shelf cell aspect-fills, so anything handed to it that is not 16:9 gets centre-cropped by
/// the home screen, and the bottom band it takes is where the resume bar lives. These pin that the
/// renderer does the crop itself, bar and all, rather than leaving it to a process that will cut
/// the bar off (Sodalite#128).
@Suite("Resume bar renderer")
struct ResumeBarRendererTests {

    @Test("16:9 artwork keeps every pixel")
    func sixteenNineIsUntouched() {
        #expect(ResumeBarRenderer.canvas(sourceWidth: 1024, sourceHeight: 576)
            == ResumeBarRenderer.Canvas(width: 1024, height: 576, originX: 0, originY: 0))
    }

    @Test("a 4:3 still is centre-cropped to the cell's aspect")
    func fourThreeLosesHeight() {
        // 400x300 is what Jellyfin serves for a TVDB still of a 4:3-era show.
        #expect(ResumeBarRenderer.canvas(sourceWidth: 400, sourceHeight: 300)
            == ResumeBarRenderer.Canvas(width: 400, height: 225, originX: 0, originY: -37))
    }

    @Test("a wider-than-16:9 source loses width instead")
    func ultraWideLosesWidth() {
        #expect(ResumeBarRenderer.canvas(sourceWidth: 1000, sourceHeight: 500)
            == ResumeBarRenderer.Canvas(width: 889, height: 500, originX: -55, originY: 0))
    }

    @Test("a poster-shaped source is still cropped to the cell")
    func posterLosesMostOfItsHeight() {
        #expect(ResumeBarRenderer.canvas(sourceWidth: 640, sourceHeight: 960)
            == ResumeBarRenderer.Canvas(width: 640, height: 360, originX: 0, originY: -300))
    }

    @Test("an empty source has no canvas")
    func emptySourceHasNoCanvas() {
        #expect(ResumeBarRenderer.canvas(sourceWidth: 0, sourceHeight: 300) == nil)
        #expect(ResumeBarRenderer.canvas(sourceWidth: 400, sourceHeight: 0) == nil)
    }

    @Test("the bar is inside the artwork a 4:3 still produces")
    func barSurvivesOnAFourThreeStill() throws {
        let rendered = try #require(ResumeBarRenderer.render(source: Self.whiteJPEG(width: 400, height: 300),
                                                             fraction: 0.35,
                                                             accent: 0x00_7A_FF,
                                                             maxPixelSize: 1024))
        let image = try #require(Self.decode(rendered))
        #expect(image.width == 400)
        #expect(image.height == 225)

        // inset 11px, bar 7px tall: the capsule's middle row sits 14px above the bottom edge, and
        // the fill ends at 35% of a 378px track, so 60 is inside it and 300 is past it.
        let bitmap = try #require(Self.bitmap(image))
        let row = image.height - 15
        let filled = bitmap.at(60, row)
        let track = bitmap.at(300, row)
        #expect(filled.b > 200 && filled.r < 90)
        #expect(track.b < 90 && track.r < 90)
    }

    @Test("16:9 artwork comes back at its own size")
    func sixteenNineRendersAtSourceSize() throws {
        let rendered = try #require(ResumeBarRenderer.render(source: Self.whiteJPEG(width: 1024, height: 576),
                                                             fraction: 0.77,
                                                             accent: 0x00_7A_FF,
                                                             maxPixelSize: 1024))
        let image = try #require(Self.decode(rendered))
        #expect(image.width == 1024)
        #expect(image.height == 576)
    }

    // MARK: - Pixels

    private struct Bitmap {
        let bytes: [UInt8]
        let bytesPerRow: Int

        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let offset = y * bytesPerRow + x * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
    }

    private static func whiteJPEG(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func bitmap(_ image: CGImage) -> Bitmap? {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: image.width,
                                          height: image.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? Bitmap(bytes: bytes, bytesPerRow: bytesPerRow) : nil
    }
}
