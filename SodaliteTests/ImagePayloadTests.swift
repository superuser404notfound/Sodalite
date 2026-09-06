import Testing
import Foundation
import UIKit
@testable import Sodalite

/// Sodalite#123. A logo drew with its top fifth and nothing under it, and the same page a moment
/// later drew the text title instead. Both are one payload that stopped in the middle: Jellyfin
/// writes its resized-image cache straight to the final path behind a `File.Exists` check, so a
/// request that lands while another is still encoding the same box is served the half-written file
/// with a Content-Length that matches what is on disk. The transfer succeeds, and nothing in
/// URLSession or ImageIO says otherwise, so the container's end marker is the only signal there is.
struct ImagePayloadTests {

    // MARK: helpers

    /// Noise, not a flat fill: a real logo compresses into many IDAT chunks, and a cut inside them
    /// is what the field case is made of.
    private func noiseImage(width: Int = 400, height: Int = 160) -> UIImage {
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size).image { context in
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 4) {
                    UIColor(red: .random(in: 0...1), green: .random(in: 0...1),
                            blue: .random(in: 0...1), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 2))
                }
            }
        }
    }

    private func png() -> Data { noiseImage().pngData()! }
    private func jpeg() -> Data { noiseImage().jpegData(compressionQuality: 0.9)! }

    private func cut(_ data: Data, to fraction: Double) -> Data {
        Data(data.prefix(Int(Double(data.count) * fraction)))
    }

    // MARK: the defect this exists for

    @Test("a PNG cut to a fifth still decodes, at the full declared size, so only the bytes can tell")
    func truncatedPNGDecodesAnyway() {
        let whole = png()
        let front = cut(whole, to: 0.2)

        // ImageIO does not refuse the front of a PNG, and it does not shrink the image it hands
        // back either: the frame is sized correctly and the missing rows are simply transparent,
        // which is why the defect reads as a logo with its bottom cut off rather than as a failure.
        #expect(UIImage(data: front) != nil)
        #expect(UIImage(data: front)?.size == UIImage(data: whole)?.size)

        #expect(ImagePayload.isComplete(front) == false)
        #expect(ImagePayload.isComplete(whole))
    }

    // MARK: per format

    @Test("a whole PNG carries its IEND chunk, every cut of one does not")
    func pngTrailer() {
        let whole = png()
        #expect(ImagePayload.isComplete(whole))
        for fraction in [0.2, 0.5, 0.9, 0.999] {
            #expect(ImagePayload.isComplete(cut(whole, to: fraction)) == false,
                    "a PNG cut to \(fraction) passed as whole")
        }
    }

    @Test("a whole JPEG ends in EOI, every cut of one does not")
    func jpegEndOfImage() {
        let whole = jpeg()
        #expect(ImagePayload.isComplete(whole))
        for fraction in [0.2, 0.5, 0.9, 0.999] {
            #expect(ImagePayload.isComplete(cut(whole, to: fraction)) == false,
                    "a JPEG cut to \(fraction) passed as whole")
        }
    }

    @Test("a WebP is measured against the length its RIFF header declares")
    func webPDeclaredLength() {
        // RIFF <uint32 LE payload length> WEBP + payload. 20 bytes of payload, so the field is 28.
        var whole = Data("RIFF".utf8)
        whole.append(contentsOf: [28, 0, 0, 0])
        whole.append(Data("WEBPVP8 ".utf8))
        whole.append(Data(repeating: 0x42, count: 20))
        #expect(whole.count == 36)
        #expect(ImagePayload.isComplete(whole))
        #expect(ImagePayload.isComplete(whole.prefix(30)) == false)
    }

    @Test("a GIF ends in its trailer byte")
    func gifTrailer() {
        var whole = Data("GIF89a".utf8)
        whole.append(Data(repeating: 0x11, count: 24))
        whole.append(0x3B)
        #expect(ImagePayload.isComplete(whole))
        #expect(ImagePayload.isComplete(whole.dropLast()) == false)
    }

    // MARK: what it must NOT refuse

    @Test("a format with no cheap end marker is taken at face value, not refused")
    func unknownFormatPasses() {
        // HEIC/AVIF/SVG and anything else: there is nothing here to be sure about, and refusing on
        // a guess would blank artwork that is perfectly fine.
        var heic = Data(repeating: 0, count: 4)
        heic.append(Data("ftypheic".utf8))
        heic.append(Data(repeating: 0x7F, count: 64))
        #expect(ImagePayload.isComplete(heic))
    }

    @Test("nothing at all is not a whole image")
    func emptyAndStubPayloads() {
        // The other shape Jellyfin's cache produces: a zero-length file, created and not yet
        // written. It has no format to sniff, and it is certainly not an image.
        #expect(ImagePayload.isComplete(Data()) == false)
        #expect(ImagePayload.isComplete(Data(repeating: 0, count: 8)) == false)
    }
}
