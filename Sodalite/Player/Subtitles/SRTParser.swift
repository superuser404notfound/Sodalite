import Foundation
import AetherEngine

// `SubtitleCue` lives in AetherEngine; this HTTP/sidecar fallback feeds the same type as the
// engine's embedded-stream decoder so both paths land on one overlay renderer.

/// Parses SRT (SubRip) and WebVTT subtitle files into timed cues.
enum SRTParser {

    nonisolated private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]+>")
    nonisolated private static let assOverridePattern = try! NSRegularExpression(pattern: #"\{\\[^}]*\}"#)

    nonisolated private static func stripMarkup(_ text: String) -> String {
        var result = text
        for regex in [tagPattern, assOverridePattern] {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    /// `@concurrent`: a 2,500 cue file took some 27 ms of regex work on a Mac, more on an Apple TV,
    /// and this was called on the main actor (audit PUI-204). The patterns compile once.
    @concurrent nonisolated static func parse(_ content: String) async -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")

            if lines.first?.hasPrefix("WEBVTT") == true { continue }

            guard let timingIdx = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingLine = lines[timingIdx]
            guard let (start, end) = parseTimingLine(timingLine) else { continue }

            let textLines = lines[(timingIdx + 1)...]
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }

            // `{\...}` is an ASS override block: Jellyfin's ASS-to-SRT conversion (ffmpeg srtenc) keeps
            // `{\an8}` and friends for non-bottom placement. A brace without the backslash is text.
            let cleanText = stripMarkup(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }

            cues.append(SubtitleCue(
                id: cues.count,
                startTime: start,
                endTime: end,
                body: .text(cleanText)
            ))
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    /// Parse a timing line like "00:01:23,456 --> 00:01:26,789"
    nonisolated private static func parseTimingLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        guard let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }

        return (start, end)
    }

    /// Parse a timestamp like "00:01:23,456" or "00:01:23.456" to seconds.
    nonisolated private static func parseTimestamp(_ ts: String) -> Double? {
        // Drop WebVTT position metadata trailing the timestamp.
        let clean = ts.components(separatedBy: " ").first ?? ts

        let normalized = clean.replacingOccurrences(of: ",", with: ".")

        let parts = normalized.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        if parts.count == 3 {
            // HH:MM:SS.mmm
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            // Double() parses "inf"/"nan"/overflow into non-finite values; reject them so a
            // malformed line can't admit an Inf endTime (stuck cue + O(n) per-tick lookup).
            let result = h * 3600 + m * 60 + s
            guard result.isFinite else { return nil }
            return result
        } else {
            // MM:SS.mmm
            guard let m = Double(parts[0]),
                  let s = Double(parts[1]) else { return nil }
            let result = m * 60 + s
            guard result.isFinite else { return nil }
            return result
        }
    }
}
