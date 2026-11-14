import Testing
@testable import Sodalite

struct FrameRateFormatTests {
    @Test func fractionalRatesKeepTheirDecimals() {
        #expect(FrameRateFormat.fps(24000.0 / 1001) == "23.976 fps")
        #expect(FrameRateFormat.fps(23.976025) == "23.976 fps")
        #expect(FrameRateFormat.fps(30000.0 / 1001) == "29.97 fps")
        #expect(FrameRateFormat.fps(60000.0 / 1001) == "59.94 fps")
    }

    @Test func wholeRatesDropTheZeros() {
        #expect(FrameRateFormat.fps(24) == "24 fps")
        #expect(FrameRateFormat.fps(25) == "25 fps")
        #expect(FrameRateFormat.fps(50) == "50 fps")
    }

    @Test func measuredRefreshSnapsToTheModeButNotAcrossTheNTSCStep() {
        #expect(FrameRateFormat.hz(23.9758) == "23.976 Hz")
        #expect(FrameRateFormat.hz(24.0021) == "24 Hz")
        #expect(FrameRateFormat.hz(59.9993) == "60 Hz")
        #expect(FrameRateFormat.hz(59.9402) == "59.94 Hz")
        #expect(FrameRateFormat.hz(57.5) == "57.5 Hz")
    }

    @Test func windowNeedsASecondBeforeItAnswers() {
        var window = RefreshWindow()
        for i in 0..<30 { window.add(timestamp: Double(i) / 60, frameDuration: 1.0 / 60) }
        #expect(window.rate == nil)
        for i in 30..<180 { window.add(timestamp: Double(i) / 60, frameDuration: 1.0 / 60) }
        #expect(abs(window.rate! - 60) < 0.001)
    }

    @Test func skippedTicksStillCountAsRefreshes() {
        var window = RefreshWindow()
        let period = 1001.0 / 60000
        // Every third tick lost to a busy main thread.
        for i in 0..<300 where i % 3 != 0 { window.add(timestamp: Double(i) * period, frameDuration: period) }
        #expect(FrameRateFormat.hz(window.rate!) == "59.94 Hz")
    }

    @Test func modeSwitchDropsTheOldHistory() {
        var window = RefreshWindow()
        for i in 0..<180 { window.add(timestamp: Double(i) / 60, frameDuration: 1.0 / 60) }
        let start = 3.5
        let period = 1001.0 / 24000
        for i in 0..<10 { window.add(timestamp: start + Double(i) * period, frameDuration: period) }
        #expect(window.rate == nil)
        for i in 10..<72 { window.add(timestamp: start + Double(i) * period, frameDuration: period) }
        #expect(FrameRateFormat.hz(window.rate!) == "23.976 Hz")
    }
}
