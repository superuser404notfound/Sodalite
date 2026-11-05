import Testing
import AetherEngine
@testable import Sodalite

/// AE#983: the scan rides on the resolution, and the deinterlacer gets its own row.
struct StatsScanDeinterlaceTests {

    @Test func theScanRidesOnTheHeight() {
        func label(_ scan: VideoScan) -> String? {
            StatsOverlayView.resolutionLabel(engineWidth: 1920, engineHeight: 1080, file: nil, scan: scan)
        }
        #expect(label(.unknown) == "1920×1080")
        #expect(label(.progressive) == "1920×1080p")
        #expect(label(.interlaced(.topFieldFirst)) == "1920×1080i · TFF")
        #expect(label(.interlaced(.bottomFieldFirst)) == "1920×1080i · BFF")
        #expect(label(.interlaced(.unknown)) == "1920×1080i")
    }

    @Test func noResolutionStaysNoResolutionWhateverTheScan() {
        #expect(StatsOverlayView.resolutionLabel(
            engineWidth: 0, engineHeight: 0, file: nil, scan: .progressive) == nil)
    }

    @Test func theDeinterlacerNamesItsFilterWhereItRunsAndTheOutputRate() {
        let gpu = VideoDeinterlace(filter: "yadif_videotoolbox", isHardware: true, fieldRate: .field)
        let cpu = VideoDeinterlace(filter: "bwdif", isHardware: false, fieldRate: .frame)
        #expect(StatsOverlayView.deinterlaceLabel(gpu, sourceFrameRate: 25) == "yadif_videotoolbox (GPU) → 50 fps")
        #expect(StatsOverlayView.deinterlaceLabel(gpu, sourceFrameRate: 29.97) == "yadif_videotoolbox (GPU) → 59.9 fps")
        #expect(StatsOverlayView.deinterlaceLabel(cpu, sourceFrameRate: 25) == "bwdif (CPU) → 25 fps")
        #expect(StatsOverlayView.deinterlaceLabel(cpu, sourceFrameRate: nil) == "bwdif (CPU)")
    }
}
