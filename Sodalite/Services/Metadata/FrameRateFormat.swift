import Foundation

/// Frame and refresh rates as people who care about them write them: "23.976", "24", "29.97", "59.94".
/// A `%g` format rounds 23.976 to "24", which hides exactly the difference a judder report is about
/// (Sodalite#239).
enum FrameRateFormat {
    /// Up to three decimals, trailing zeros dropped. 24000/1001 reads "23.976", 30000/1001 "29.97".
    static func number(_ rate: Double) -> String {
        var text = String(format: "%.3f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func fps(_ rate: Double) -> String {
        number(rate) + " fps"
    }

    /// The HDMI and panel modes an Apple TV can land on. A measured rate this close to one of them IS that
    /// mode; the tolerance is far below the 0.1% between 23.976 and 24, so the two never blur.
    static let standardRefreshRates: [Double] = [
        24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48000.0 / 1001, 48, 50,
        60000.0 / 1001, 60, 100, 120000.0 / 1001, 120,
    ]

    static func snappedRefreshRate(_ measured: Double) -> Double {
        standardRefreshRates.first { abs($0 - measured) / $0 < 0.0002 } ?? measured
    }

    static func hz(_ measured: Double) -> String {
        number(snappedRefreshRate(measured)) + " Hz"
    }
}
