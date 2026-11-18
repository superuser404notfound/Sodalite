import Testing
import Foundation
@testable import Sodalite

/// Audit CMP-R201: one clock formatter in place of five copies. The padded variant is the player's.
struct TimeIntervalClockTests {
    @Test func unpaddedMatchesTheDetailAndMusicSurfaces() {
        #expect(TimeInterval(303).clockDisplay() == "5:03")
        #expect(TimeInterval(0).clockDisplay() == "0:00")
        #expect(TimeInterval(3_765).clockDisplay() == "1:02:45")
        #expect(TimeInterval(7_200).clockDisplay() == "2:00:00")
    }

    @Test func paddedMatchesThePlayerBelowAnHour() {
        #expect(TimeInterval(303).clockDisplay(padMinutes: true) == "05:03")
        #expect(TimeInterval(0).clockDisplay(padMinutes: true) == "00:00")
        #expect(TimeInterval(3_765).clockDisplay(padMinutes: true) == "1:02:45")
    }

    @Test func oddInputReadsAsZeroOrClampsInsteadOfTrapping() {
        #expect(TimeInterval.infinity.clockDisplay() == "0:00")
        #expect(TimeInterval.nan.clockDisplay() == "0:00")
        #expect(TimeInterval(-5).clockDisplay() == "0:00")
        #expect(TimeInterval(1e300).clockDisplay().hasSuffix(":59:59"))
    }

    @Test func existingCallersKeepTheirFormat() {
        #expect(MusicTimeFormatter.string(65.9) == "1:05")
        #expect(MusicTimeFormatter.string(.infinity) == "0:00")
        #expect(ResumeTimeFormatter.format(ticks: 3_030_000_000) == "5:03")
        #expect(ResumeTimeFormatter.format(ticks: 0) == nil)
    }
}
