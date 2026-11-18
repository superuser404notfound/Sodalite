import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Characterizes SRT/WebVTT parsing, including the non-finite timestamp guard (commit 8da3bddd).
@MainActor
struct SRTParserTests {
    private func text(_ cue: SubtitleCue?) -> String? {
        guard let cue, case .text(let body) = cue.body else { return nil }
        return body
    }

    @Test func parsesBasicSRTBlock() async {
        let cues = await SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\nHello")
        #expect(cues.count == 1)
        #expect(cues[0].startTime == 1.0)
        #expect(cues[0].endTime == 2.0)
        #expect(text(cues[0]) == "Hello")
    }

    @Test func stripsHTMLTags() async {
        let cues = await SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Hi</i> <b>there</b>")
        #expect(text(cues.first) == "Hi there")
    }

    /// Jellyfin's ASS-to-SRT conversion keeps override blocks such as `{\an8}` for top placement.
    @Test func stripsASSOverrideBlocks() async {
        let cues = await SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\n{\\an8}Top line\n{\\i1}Second{\\i0}")
        #expect(text(cues.first) == "Top line\nSecond")
    }

    @Test func keepsLiteralBracesThatAreNotOverrideTags() async {
        let cues = await SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\n{laughs} a set {1, 2}")
        #expect(text(cues.first) == "{laughs} a set {1, 2}")
    }

    @Test func dropsACueThatIsOnlyAnOverrideBlock() async {
        let cues = await SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\n{\\an8}\n\n2\n00:00:03,000 --> 00:00:04,000\nKept")
        #expect(cues.count == 1)
        #expect(text(cues.first) == "Kept")
    }

    @Test func skipsWebVTTHeaderBlock() async {
        let content = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nCaption"
        let cues = await SRTParser.parse(content)
        #expect(cues.count == 1)
        #expect(text(cues[0]) == "Caption")
    }

    @Test func parsesMMSSTimestamp() async {
        let cues = await SRTParser.parse("00:01.500 --> 00:02.000\nShort")
        #expect(cues.count == 1)
        #expect(cues[0].startTime == 1.5)
    }

    @Test func dropsBlockWithNonFiniteTimestamp() async {
        // A huge mantissa overflows Double to inf; the guard must drop that block, not admit an Inf endTime.
        let content = "1e400:00:00,000 --> 00:00:05,000\nBad\n\n00:00:03,000 --> 00:00:04,000\nGood"
        let cues = await SRTParser.parse(content)
        #expect(cues.count == 1)
        #expect(text(cues[0]) == "Good")
    }

    @Test func dropsBlockWithEmptyText() async {
        let cues = await SRTParser.parse("00:00:01,000 --> 00:00:02,000\n   ")
        #expect(cues.isEmpty)
    }

    @Test func sortsCuesByStartTime() async {
        let content = "00:00:05,000 --> 00:00:06,000\nSecond\n\n00:00:01,000 --> 00:00:02,000\nFirst"
        let cues = await SRTParser.parse(content)
        #expect(cues.map { self.text($0) } == ["First", "Second"])
    }

    @Test func hugeFileKeepsEveryCue() async {
        var content = ""
        for i in 0..<2_500 {
            content += "\(i + 1)\n00:\(String(format: "%02d", i / 60 % 60)):\(String(format: "%02d", i % 60)),000 --> 00:\(String(format: "%02d", i / 60 % 60)):\(String(format: "%02d", i % 60)),500\n<i>Line \(i)</i> {\\an8}\n\n"
        }
        let cues = await SRTParser.parse(content)
        #expect(cues.count == 2_500)
        #expect(text(cues[7]) == "Line 7")
    }
}
