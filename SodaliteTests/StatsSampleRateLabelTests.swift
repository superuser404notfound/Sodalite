import Testing
@testable import Sodalite

/// AE#658. The audio sample rate row reads in kHz, with a decimal only where the rate needs one.
@Suite("Stats sample rate label")
struct StatsSampleRateLabelTests {
    @Test("Whole kilohertz rates carry no decimal")
    func wholeKilohertz() {
        #expect(StatsOverlayView.formatSampleRate(48_000) == "48 kHz")
        #expect(StatsOverlayView.formatSampleRate(192_000) == "192 kHz")
    }

    @Test("CD-family rates keep their decimal")
    func fractionalKilohertz() {
        #expect(StatsOverlayView.formatSampleRate(44_100) == "44.1 kHz")
        #expect(StatsOverlayView.formatSampleRate(88_200) == "88.2 kHz")
    }
}
