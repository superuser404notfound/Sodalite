import Foundation

/// The width a Jellyfin transcode will pick at a bitrate cap (Sodalite#87), so the quality picker can say
/// what a rung produces for the file on screen instead of printing a fixed resolution the rung never
/// enforces. Mirrors the server: `StreamBuilder` takes the audio's share off the cap,
/// `EncodingHelper.ScaleBitrate` turns the video bitrate into its H.264 equivalent, and
/// `ResolutionNormalizer` looks the width up after correcting for the frame rate. Pinned against an
/// iPhone's measurements on a 4K HEVC source: 4 Mbit/s gave 1280 wide in H.264 and 1920 in HEVC.
enum TranscodeResolutionEstimate {
    /// The audio share Jellyfin took off the cap in the measured transcode URL (VideoBitrate 3744000 at a
    /// 4 Mbit/s cap).
    static let audioBitrate = 256_000

    /// `ResolutionNormalizer`'s table: the widest width a reference (H.264, 30 fps) bitrate buys.
    private static let table: [(width: Int, maxBitrate: Double)] = [
        (416, 365_000), (640, 730_000), (768, 1_100_000), (960, 3_000_000),
        (1280, 6_000_000), (1920, 13_500_000), (2560, 28_000_000), (3840, 50_000_000),
    ]

    /// nil only where neither the table nor the source bounds the width.
    static func width(cap: Int, outputCodec: String, frameRate: Double?, sourceWidth: Int?) -> Int? {
        let video = max(cap - audioBitrate, 0)
        let h264Equivalent = Double(scaleToH264(video, from: outputCodec))
        let fps = frameRate.flatMap { $0 > 0 ? $0 : nil } ?? 30
        let fpsScale = fps <= 30 ? 30 / fps : 1 / (fps / 30).squareRoot()
        let reference = h264Equivalent * fpsScale
        guard let entry = table.first(where: { reference <= $0.maxBitrate }) else { return sourceWidth }
        return min(entry.width, sourceWidth ?? entry.width)
    }

    /// `EncodingHelper.ScaleBitrate(bitrate, outputCodec, "h264")`, floors and 30 Mbit/s ceiling included.
    private static func scaleToH264(_ bitrate: Int, from codec: String) -> Int {
        var scale = max(1 / efficiency(codec), 1)
        if bitrate <= 500_000 { scale = max(scale, 4) }
        else if bitrate <= 1_000_000 { scale = max(scale, 3) }
        else if bitrate <= 2_000_000 { scale = max(scale, 2.5) }
        else if bitrate <= 3_000_000 { scale = max(scale, 2) }
        else if bitrate >= 30_000_000 { scale = 1 }
        return Int(scale * Double(bitrate))
    }

    private static func efficiency(_ codec: String) -> Double {
        switch codec.lowercased() {
        case "hevc", "h265", "vp9": return 0.6
        case "av1": return 0.5
        default: return 1
        }
    }

    /// The name people use for a width. By width rather than height, so a 3840x1600 scope film reads 4K.
    static func label(width: Int) -> String {
        switch width {
        case 3200...: return "4K"
        case 2400...: return "1440p"
        case 1600...: return "1080p"
        case 1100...: return "720p"
        case 900...: return "540p"
        case 700...: return "480p"
        case 560...: return "360p"
        default: return "240p"
        }
    }
}
