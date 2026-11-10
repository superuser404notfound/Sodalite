import Foundation
import CoreGraphics

/// A program's airtime, reduced to what the row geometry needs.
struct GuideTimeRange: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// Overlap resolution for one channel's programs.
///
/// EPG data is not guaranteed to be disjoint. IPTV providers routinely ship a channel whose
/// programs overlap, and drawn literally that stacks two cells on the same pixels: the one behind
/// is invisible but still focusable, so focus lands on a program the user cannot see and the one on
/// top looks like it has a rounded blob poking out beside it.
enum GuideRowMath {

    /// Indices to keep, in order. An entry that ends no later than something already kept is fully
    /// covered, carries nothing the row does not already show, and is dropped so it can never take
    /// focus. Entries without airtimes are kept: they render as the row-wide fallback.
    ///
    /// Expects `ranges` sorted by start.
    static func keptIndices(_ ranges: [GuideTimeRange?]) -> [Int] {
        var kept: [Int] = []
        var cursor = Date.distantPast
        for (index, range) in ranges.enumerated() {
            guard let range else {
                kept.append(index)
                continue
            }
            guard range.end > cursor else { continue }
            kept.append(index)
            cursor = max(cursor, range.end)
        }
        return kept
    }

    /// Content-space x and width per entry, with partial overlaps trimmed: an entry that starts
    /// before its predecessor ends begins where the predecessor ends instead. The times shown in the
    /// cell stay the program's own, only the geometry moves, so a trimmed program still reads
    /// truthfully while the row keeps one cell per column of pixels.
    ///
    /// Expects `ranges` sorted by start, and already filtered through `keptIndices`.
    static func spans(_ ranges: [GuideTimeRange?], axis: GuideAxis) -> [(x: CGFloat, width: CGFloat)] {
        var result: [(x: CGFloat, width: CGFloat)] = []
        var cursor: CGFloat = 0
        for range in ranges {
            guard let range else {
                result.append((0, axis.totalWidth))
                cursor = axis.totalWidth
                continue
            }
            let rawX = max(0, axis.x(for: range.start))
            let right = rawX + axis.width(from: range.start, to: range.end)
            let x = max(rawX, cursor)
            result.append((x, max(0, right - x)))
            cursor = max(cursor, right)
        }
        return result
    }
}

extension GuideRowMath {
    /// Content offset that makes a focused span readable, or nil when it already is.
    ///
    /// Vertical moves in the grid keep the time position rather than following the cell, so focus
    /// can land on a program that only just reaches into the viewport. The focus engine does not
    /// scroll for that: the program shows as a rounded stub at the very edge while the hero
    /// describes it in full.
    static func offsetToReveal(span: (x: CGFloat, width: CGFloat),
                               offset: CGFloat,
                               viewport: CGFloat,
                               minimumVisible: CGFloat,
                               maxOffset: CGFloat) -> CGFloat? {
        guard span.width > 0, viewport > 0 else { return nil }
        let visible = min(span.x + span.width, offset + viewport) - max(span.x, offset)
        // A cell narrower than the threshold only has to be fully visible.
        guard visible < min(span.width, minimumVisible) else { return nil }
        // Reached from the left: start it where a jump would. From the right: pull its end in, so a
        // long block does not scroll the user past everything they were looking at.
        let target = span.x < offset
            ? span.x - viewport * 0.08
            : span.x + span.width - viewport * 0.92
        let clamped = min(max(0, target), maxOffset)
        return abs(clamped - offset) > 1 ? clamped : nil
    }
}

extension JellyfinProgram {
    /// nil when either end is missing, which is what the row-wide fallback keys off.
    var guideTimeRange: GuideTimeRange? {
        guard let startDate, let endDate else { return nil }
        return GuideTimeRange(start: startDate, end: endDate)
    }
}

/// One cell of a guide row: a program from the EPG, or a stretch the EPG says nothing about.
enum GuideRowEntry: Equatable {
    case program(Int)
    case gap(GuideTimeRange)
}

extension GuideRowMath {
    /// Sodalite#221: the anchor is compared at minute resolution, the resolution the grid prints.
    /// EPG times often carry seconds (an "11:00-11:30" program ending at 11:30:20), and a cell's
    /// time read back from its x can land a fraction of a second either side of the minute. Both
    /// made a program that visibly ENDS at the picked time beat the one that starts at it.
    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    static func roundToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    /// Index of the entry whose airtime covers `time`, nil when none does.
    static func index(covering time: Date, in ranges: [GuideTimeRange?]) -> Int? {
        let minute = floorToMinute(time)
        return ranges.firstIndex { range in
            guard let range else { return false }
            return floorToMinute(range.start) <= minute && minute < floorToMinute(range.end)
        }
    }

    /// The covering entry, or the nearest one when the row has a gap at `time`. nil for no entries.
    static func index(coveringOrNearest time: Date, in ranges: [GuideTimeRange?]) -> Int? {
        if let covering = index(covering: time, in: ranges) { return covering }
        var best: Int?
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        for (index, range) in ranges.enumerated() {
            guard let range else { continue }
            let distance = time < range.start
                ? range.start.timeIntervalSince(time)
                : time.timeIntervalSince(range.end)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best ?? (ranges.isEmpty ? nil : 0)
    }

    /// Sodalite#221: a channel whose EPG ends hours before the axis does left nothing focusable at a
    /// picked time past that end, so the anchor fell back to the row's LAST program and a vertical
    /// move landed hours early and scrolled the grid back to it. Stretches of at least
    /// `minimumGapMinutes` without data become placeholder entries, cut on the same hourly lines as
    /// a channel with no EPG at all, so there is always a cell at the anchor.
    ///
    /// Expects `ranges` sorted by start and filtered through `keptIndices`. A row with an entry
    /// without airtimes is returned unchanged: that entry already spans the whole axis.
    static func entriesFillingGaps(_ ranges: [GuideTimeRange?], axis: GuideAxis,
                                   segmentMinutes: Int,
                                   minimumGapMinutes: Int = GuideAxis.slotMinutes) -> [GuideRowEntry] {
        let programs = ranges.indices.map { GuideRowEntry.program($0) }
        guard !ranges.isEmpty, !ranges.contains(where: { $0 == nil }) else { return programs }
        let minimumGap = TimeInterval(minimumGapMinutes) * 60
        let segment = TimeInterval(segmentMinutes) * 60
        var result: [GuideRowEntry] = []
        var cursor = axis.start

        func fill(to end: Date) {
            guard end.timeIntervalSince(cursor) >= minimumGap else { return }
            var start = cursor
            while start < end {
                // Next hourly line at least a minimum gap away, so no sliver cells.
                let steps = ((start.timeIntervalSince(axis.start) + minimumGap) / segment).rounded(.up)
                var stop = axis.start.addingTimeInterval(steps * segment)
                if end.timeIntervalSince(stop) < minimumGap { stop = end }
                result.append(.gap(GuideTimeRange(start: start, end: stop)))
                start = stop
            }
        }

        for (index, range) in ranges.enumerated() {
            guard let range else { continue }
            fill(to: min(range.start, axis.end))
            result.append(.program(index))
            cursor = max(cursor, range.end)
        }
        fill(to: axis.end)
        return result
    }
}
