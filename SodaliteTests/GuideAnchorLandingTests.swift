import Testing
import Foundation
@testable import Sodalite

/// Sodalite#221 retest on build 8: at a picked time, a fast swipe landed early in two ways. A
/// program that visibly ended at the picked time beat the one starting at it, depending on seconds
/// the grid does not show, and a channel whose EPG ended hours earlier sent focus to its last program.
@Suite("Guide anchor landing")
struct GuideAnchorLandingTests {

    /// A multiple of 1800, so the axis starts here in every half-hour timezone.
    private let base = Date(timeIntervalSince1970: 1_754_388_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func range(_ start: Double, _ end: Double) -> GuideTimeRange {
        GuideTimeRange(start: at(start), end: at(end))
    }

    private func axis(hours: Double = 6) -> GuideAxis {
        GuideAxis(now: base, pointsPerMinute: 8, guideEnd: at(hours * 60))
    }

    // MARK: - Boundaries

    @Test("an EPG end a few seconds past the picked minute does not beat the program starting then")
    func endingProgramLosesOnSeconds() {
        let ranges: [GuideTimeRange?] = [range(0, 30 + 20.0 / 60), range(30 + 20.0 / 60, 60)]
        #expect(GuideRowMath.index(coveringOrNearest: at(30), in: ranges) == 1)
    }

    @Test("a start a few seconds past the picked minute still covers it")
    func lateStartCoversTheMinute() {
        let ranges: [GuideTimeRange?] = [range(0, 30 + 5.0 / 60), range(30 + 5.0 / 60, 60)]
        #expect(GuideRowMath.index(covering: at(30), in: ranges) == 1)
    }

    @Test("live inside the last minute of a program stays on it")
    func liveStaysOnAiringProgram() {
        let ranges: [GuideTimeRange?] = [range(0, 30), range(30, 60)]
        #expect(GuideRowMath.index(covering: at(29 + 40.0 / 60), in: ranges) == 0)
    }

    @Test("a picked time read back from x a hair short of the minute lands on that minute")
    func pickedTimeIsRounded() {
        let now = base
        let start = at(30).addingTimeInterval(-0.000_01)
        #expect(GuideAnchor.focused(start: start, visibleStart: base, now: now) == .at(at(30)))
    }

    // MARK: - Rows whose EPG ends early

    @Test("an EPG ending hours before the axis gets placeholders up to the axis end")
    func trailingGapIsFilled() {
        let ranges: [GuideTimeRange?] = [range(0, 60), range(60, 90)]
        let entries = GuideRowMath.entriesFillingGaps(ranges, axis: axis(hours: 4), segmentMinutes: 60)
        #expect(entries == [.program(0), .program(1),
                            .gap(range(90, 120)), .gap(range(120, 180)), .gap(range(180, 240))])
    }

    @Test("a picked time past the EPG lands on the placeholder there, not the last program")
    func anchorPastEPGLandsOnPlaceholder() {
        let ranges: [GuideTimeRange?] = [range(0, 60), range(60, 90)]
        let entries = GuideRowMath.entriesFillingGaps(ranges, axis: axis(hours: 4), segmentMinutes: 60)
        let filled = entries.map { entry -> GuideTimeRange? in
            switch entry {
            case .program(let index): ranges[index]
            case .gap(let gap): gap
            }
        }
        #expect(GuideRowMath.index(coveringOrNearest: at(150), in: filled) == 3)
    }

    @Test("a leading gap and a long gap between programs are filled, short ones are not")
    func innerGaps() {
        let ranges: [GuideTimeRange?] = [range(45, 60), range(70, 100), range(220, 240)]
        let entries = GuideRowMath.entriesFillingGaps(ranges, axis: axis(hours: 4), segmentMinutes: 60)
        #expect(entries == [.gap(range(0, 45)), .program(0), .program(1),
                            .gap(range(100, 180)), .gap(range(180, 220)), .program(2)])
    }

    @Test("no placeholder sliver right before an hourly line")
    func noSliver() {
        let ranges: [GuideTimeRange?] = [range(0, 50)]
        let entries = GuideRowMath.entriesFillingGaps(ranges, axis: axis(hours: 3), segmentMinutes: 60)
        #expect(entries == [.program(0), .gap(range(50, 120)), .gap(range(120, 180))])
    }

    @Test("a row with a program without airtimes is left alone")
    func rowWideFallbackUntouched() {
        let ranges: [GuideTimeRange?] = [nil]
        #expect(GuideRowMath.entriesFillingGaps(ranges, axis: axis(), segmentMinutes: 60)
                == [.program(0)])
    }
}
