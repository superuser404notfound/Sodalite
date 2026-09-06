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

/// One image request, plus the refusal that has to follow a payload which stopped in the middle.
///
/// The gate above was not enough on its own. Jellyfin answers image requests with
/// `Cache-Control: public` and no `max-age`, a `Last-Modified` at ONE-SECOND granularity and no
/// ETag (measured against 10.10.7, 2026-09-06), so URLSession stores the half-written body and asks
/// again with an `If-Modified-Since` that the finished file, written inside the same second, does
/// not beat. The server answers 304 and URLSession hands back the SAME truncated bytes. Measured
/// against a server built to that shape: the three-pass ladder and every later visit all read
/// 73438 bytes of a 367194-byte PNG, for the life of the cache entry, while the file on the server
/// had been whole since the first pass.
///
/// So a refused payload is dropped from the HTTP cache, and a retry asks the server rather than the
/// cache. Without both halves the ladder is three reads of one answer (Sodalite#123).
enum ImageFetch {

    enum Outcome {
        /// A 2xx whose body carries its format's end marker.
        case whole(Data)
        /// A complete HTTP response whose body is only the front of an image.
        case incomplete
        /// A non-2xx, or a cancelled task. Asking again reads the same.
        case noImage
        /// Connection-level. Worth another try when the app or the network comes back.
        case transientFailure
    }

    /// The first pass reads the HTTP cache like any other request. Every later one bypasses it: the
    /// only reason there IS a later one is that the last answer was half a file, and that is exactly
    /// what the cache would hand back.
    nonisolated static func cachePolicy(forAttempt attempt: Int) -> URLRequest.CachePolicy {
        attempt == 0 ? .useProtocolCachePolicy : .reloadIgnoringLocalCacheData
    }

    nonisolated static func load(_ request: URLRequest, attempt: Int = 0) async -> Outcome {
        var request = request
        request.cachePolicy = cachePolicy(forAttempt: attempt)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { return .noImage }
            guard ImagePayload.isComplete(data) else {
                forget(request)
                LogTap.shared.note("[Image] payload stops short at \(data.count) bytes: \(request.url?.absoluteString ?? "")")
                return .incomplete
            }
            return .whole(data)
        } catch is CancellationError {
            return .noImage
        } catch let error as URLError where error.code == .cancelled {
            return .noImage
        } catch {
            LogTap.shared.note("[Image] fetch failed \(request.url?.absoluteString ?? ""): \(error)")
            return .transientFailure
        }
    }

    /// Drops the stored response so the next request is a real one. It runs on the LAST refusal too:
    /// leaving the entry behind is what made a second visit to the page read the same half file.
    nonisolated private static func forget(_ request: URLRequest) {
        URLSession.shared.configuration.urlCache?.removeCachedResponse(for: request)
    }
}
