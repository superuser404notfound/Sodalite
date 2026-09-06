import Foundation

/// Whether a downloaded payload is a WHOLE image or only the front of one.
///
/// Jellyfin writes its resized-image cache straight to the final path (`SKFileWStream`, no temp file
/// and no atomic rename) behind a plain `File.Exists` check, so a request that arrives while another
/// one is still encoding the same box is handed the half-written file, with a Content-Length that
/// matches what is on disk at that moment. The transfer therefore SUCCEEDS: URLSession reports no
/// error, and `UIImage(data:)` returns an image at the full declared size whose lower rows are
/// transparent. Sodalite#123 is that image, a title logo drawn with its top fifth and nothing under
/// it, and, when the cut lands before the first rows, the text title in its place.
///
/// Neither of the two obvious signals exists (both measured 2026-09-06): the byte count matches the
/// Content-Length, because the server is honest about the file it has; and ImageIO answers
/// `.statusComplete` for a PNG cut to a fifth, through a plain source and an incremental one alike.
/// What is left is the container's own end marker, which is what this reads.
enum ImagePayload {

    /// True for a payload that carries its format's end marker, and for one whose format has no
    /// cheap marker to look for. False is a refusal, so it is only returned on evidence.
    nonisolated static func isComplete(_ data: Data) -> Bool {
        // Below any real image's header, so there is nothing to sniff and nothing to trust. The
        // zero-length file is the other shape the same cache race produces.
        guard data.count >= 16 else { return false }

        switch format(of: data) {
        case .png: return tail(of: data).contains(subsequence: Self.pngEndChunk)
        case .jpeg: return tail(of: data).contains(subsequence: Self.jpegEndOfImage)
        case .gif: return data.last == 0x3B
        case .webP: return riffLengthIsSatisfied(data)
        case .unknown: return true
        }
    }

    // MARK: formats

    private enum Format {
        case png, jpeg, gif, webP, unknown
    }

    nonisolated private static func format(of data: Data) -> Format {
        let head = Array(data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: Array("GIF8".utf8)) { return .gif }
        if head.starts(with: Array("RIFF".utf8)), head.count == 12,
           Array(head[8..<12]) == Array("WEBP".utf8) {
            return .webP
        }
        return .unknown
    }

    /// The IEND chunk, CRC included: a length of zero, the type, and the constant checksum that
    /// always follows it. It is the last thing in a PNG, so finding it anywhere in the tail is
    /// enough, and a cut file cannot carry it at all.
    nonisolated private static let pngEndChunk: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    /// End Of Image. It cannot occur inside entropy-coded data, where a literal 0xFF is written as
    /// `FF 00`, so it means the end of the file and nothing else.
    nonisolated private static let jpegEndOfImage: [UInt8] = [0xFF, 0xD9]

    /// Enough tail to cover an encoder that pads after the end marker, short enough that a cut file
    /// cannot reach back into a place where the pattern could occur by chance.
    nonisolated private static func tail(of data: Data) -> [UInt8] { Array(data.suffix(64)) }

    /// A RIFF container states its own payload length in bytes 4..<8, little-endian, counting from
    /// byte 8. Anything shorter than that is a file that stopped early.
    nonisolated private static func riffLengthIsSatisfied(_ data: Data) -> Bool {
        let field = Array(data[data.startIndex + 4 ..< data.startIndex + 8])
        let declared = field.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return UInt64(data.count) >= UInt64(declared) + 8
    }
}

private extension Array where Element == UInt8 {
    nonisolated func contains(subsequence pattern: [UInt8]) -> Bool {
        guard pattern.count <= count else { return false }
        for start in 0...(count - pattern.count) where Array(self[start..<start + pattern.count]) == pattern {
            return true
        }
        return false
    }
}
