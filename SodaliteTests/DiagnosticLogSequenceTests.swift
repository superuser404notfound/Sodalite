import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 DIAG-8. `LogTap.lines.count` pins at 300 once the ring starts evicting from the
/// front, so `DiagnosticLogView`'s `.onChange(of: tap.lines.count)` stopped firing (the view stopped
/// following new lines), and its offset-based row id shifted by one on every append, dragging
/// whatever the reader had focused along with it. `sequenceNumber` keeps climbing past the ring cap,
/// and `DiagnosticLogView.lineID` derives a per-line id from it that survives eviction.
struct DiagnosticLogSequenceTests {

    @Test("a line's id stays the same before and after the ring starts evicting")
    func idIsStableAcrossEviction() {
        // Before eviction: buffer still growing (count == sequenceNumber). The 241st line ever
        // appended sits at offset 240 (0-based).
        let idWhileGrowing = DiagnosticLogView.lineID(sequenceNumber: 250, lineCount: 250, offset: 240)

        // 60 more lines land; once the ring passed 300 it evicted 10 from the front (310 appended,
        // 300 - 10 kept). The SAME physical line (still the 241st ever appended) now sits 10
        // positions earlier, but should resolve to the same id.
        let idAfterEviction = DiagnosticLogView.lineID(sequenceNumber: 310, lineCount: 300, offset: 230)

        #expect(idWhileGrowing == idAfterEviction)
        #expect(idWhileGrowing == 241, "the id should equal the line's own append rank")
    }

    @Test("ids are unique and increasing across one buffer snapshot")
    func idsAreUniqueAndOrderedWithinABuffer() {
        let sequenceNumber = 500
        let lineCount = 300
        let ids = (0..<lineCount).map {
            DiagnosticLogView.lineID(sequenceNumber: sequenceNumber, lineCount: lineCount, offset: $0)
        }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test("the newest line's id always equals sequenceNumber")
    func newestLineIDEqualsSequenceNumber() {
        let id = DiagnosticLogView.lineID(sequenceNumber: 812, lineCount: 300, offset: 299)
        #expect(id == 812)
    }

    @MainActor
    @Test("LogTap's sequenceNumber keeps climbing after lines.count pins at the ring cap")
    func sequenceNumberOutlivesTheRingCap() async throws {
        // Its own instance: the shared one also takes every line the app host and the tests running
        // alongside this one note, and one of those landing mid-count made this read 311.
        let tap = LogTap()
        #expect(tap.sequenceNumber == 0)

        for index in 0..<310 {
            tap.note("[Test] line \(index)")
        }
        // note(_:) hops to the main queue per call; let all 310 drain.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(300))

        #expect(tap.lines.count == 300, "the ring should have capped at 300")
        #expect(tap.sequenceNumber == 310, "sequenceNumber should count every append, not just what's buffered")
    }
}
