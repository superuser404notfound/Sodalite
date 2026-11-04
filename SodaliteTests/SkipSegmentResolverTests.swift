import Foundation
import Testing
@testable import Sodalite

@Suite("Skip segment resolver")
struct SkipSegmentResolverTests {
    private func segment(_ type: SegmentType, _ start: Double, _ end: Double) -> MediaSegment {
        MediaSegment(
            id: "\(type.rawValue)-\(start)",
            itemId: "item",
            type: type,
            startTicks: Int64(start * 10_000_000),
            endTicks: Int64(end * 10_000_000)
        )
    }

    @Test("nothing is skippable without markers")
    func noMarkers() {
        #expect(SkipSegmentResolver.active(intro: nil, recap: nil, time: 42) == nil)
    }

    @Test("the intro resolves while the playhead is inside it")
    func introInside() {
        let intro = segment(.intro, 30, 90)
        #expect(SkipSegmentResolver.active(intro: intro, recap: nil, time: 60)?.kind == .intro)
        #expect(SkipSegmentResolver.active(intro: intro, recap: nil, time: 20) == nil)
    }

    @Test("the recap resolves while the playhead is inside it")
    func recapInside() {
        let recap = segment(.recap, 5, 45)
        let resolved = SkipSegmentResolver.active(intro: nil, recap: recap, time: 10)
        #expect(resolved?.kind == .recap)
        #expect(resolved?.endSeconds == 45)
    }

    @Test("the pill hides one second before a segment ends")
    func hidesBeforeEnd() {
        let intro = segment(.intro, 30, 90)
        #expect(SkipSegmentResolver.active(intro: intro, recap: nil, time: 88.9)?.kind == .intro)
        #expect(SkipSegmentResolver.active(intro: intro, recap: nil, time: 89.5) == nil)
    }

    @Test("a marker starting at zero stays hidden for the first half second")
    func coldOpenFloor() {
        let recap = segment(.recap, 0, 40)
        #expect(SkipSegmentResolver.active(intro: nil, recap: recap, time: 0.2) == nil)
        #expect(SkipSegmentResolver.active(intro: nil, recap: recap, time: 0.6)?.kind == .recap)
    }

    @Test("the recap wins when both contain the playhead")
    func recapBeatsIntro() {
        let recap = segment(.recap, 0, 60)
        let intro = segment(.intro, 30, 90)
        #expect(SkipSegmentResolver.active(intro: intro, recap: recap, time: 40)?.kind == .recap)
    }

    @Test("a recap running straight into an intro chains to the intro after the skip")
    func chainsToIntro() {
        let recap = segment(.recap, 5, 45)
        let intro = segment(.intro, 45, 105)
        #expect(SkipSegmentResolver.active(intro: intro, recap: recap, time: 20)?.kind == .recap)
        #expect(SkipSegmentResolver.active(intro: intro, recap: recap, time: 45.1)?.kind == .intro)
    }

    @Test("every commercial break resolves on its own (Sodalite#224)")
    func commercialBreaks() {
        let breaks = [segment(.commercial, 600, 780), segment(.commercial, 1500, 1680)]
        let first = SkipSegmentResolver.active(intro: nil, recap: nil, commercials: breaks, time: 700)
        #expect(first == ActiveSkipSegment(kind: .commercial, startSeconds: 600, endSeconds: 780))
        #expect(SkipSegmentResolver.active(intro: nil, recap: nil, commercials: breaks, time: 1000) == nil)
        #expect(SkipSegmentResolver.active(intro: nil, recap: nil, commercials: breaks, time: 1600)?.startSeconds == 1500)
    }

    @Test("back-to-back breaks resolve to the next one once the first ends")
    func adjacentBreaks() {
        let breaks = [segment(.commercial, 600, 660), segment(.commercial, 660, 720)]
        #expect(SkipSegmentResolver.active(intro: nil, recap: nil, commercials: breaks, time: 650)?.startSeconds == 600)
        #expect(SkipSegmentResolver.active(intro: nil, recap: nil, commercials: breaks, time: 660.5)?.startSeconds == 660)
    }

    @Test("an intro wins over a break that overlaps it")
    func introBeforeCommercial() {
        let intro = segment(.intro, 30, 90)
        let breaks = [segment(.commercial, 60, 120)]
        #expect(SkipSegmentResolver.active(intro: intro, recap: nil, commercials: breaks, time: 70)?.kind == .intro)
        #expect(SkipSegmentResolver.active(intro: intro, recap: nil, commercials: breaks, time: 100)?.kind == .commercial)
    }

    @Test("each kind carries its own label")
    func labels() {
        #expect(SkipSegmentKind.intro.buttonLabel != SkipSegmentKind.recap.buttonLabel)
        #expect(SkipSegmentKind.recap.buttonLabel.isEmpty == false)
        #expect(SkipSegmentKind.commercial.buttonLabel != SkipSegmentKind.intro.buttonLabel)
    }
}
