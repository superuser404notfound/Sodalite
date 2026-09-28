import Testing
@testable import Sodalite

/// Sodalite#87: the picker says what a rung produces for THIS file. Jellyfin picks a transcode's width
/// from the bitrate (`ResolutionNormalizer`, fed by `EncodingHelper.ScaleBitrate`); these mirror it and
/// are pinned against what an iPhone measured on "Cars" (4K HEVC, 23.976 fps) on 2026-09-28.
struct TranscodeResolutionEstimateTests {
    private let cars = (frameRate: 23.976, width: 3840)

    @Test func fourMbitH264IsTheMeasured720p() {
        #expect(TranscodeResolutionEstimate.width(cap: 4_000_000, outputCodec: "h264",
                                                  frameRate: cars.frameRate, sourceWidth: cars.width) == 1280)
    }

    @Test func fourMbitHEVCIsTheMeasured1080p() {
        #expect(TranscodeResolutionEstimate.width(cap: 4_000_000, outputCodec: "hevc",
                                                  frameRate: cars.frameRate, sourceWidth: cars.width) == 1920)
    }

    /// Below 2 Mbit/s Jellyfin scales the bitrate by at least 2.5 before it looks the width up.
    @Test func twoMbitGetsJellyfinsLowBitrateFloor() {
        #expect(TranscodeResolutionEstimate.width(cap: 2_000_000, outputCodec: "h264",
                                                  frameRate: cars.frameRate, sourceWidth: cars.width) == 1280)
    }

    @Test func tenMbitH264Is1080p() {
        #expect(TranscodeResolutionEstimate.width(cap: 10_000_000, outputCodec: "h264",
                                                  frameRate: cars.frameRate, sourceWidth: cars.width) == 1920)
    }

    /// Past 30 Mbit/s Jellyfin stops scaling, so HEVC at 40 is read like H.264 at 40.
    @Test func fortyMbitIs4K() {
        #expect(TranscodeResolutionEstimate.width(cap: 40_000_000, outputCodec: "hevc",
                                                  frameRate: cars.frameRate, sourceWidth: cars.width) == 3840)
    }

    @Test func neverWiderThanTheSource() {
        #expect(TranscodeResolutionEstimate.width(cap: 20_000_000, outputCodec: "hevc",
                                                  frameRate: 23.976, sourceWidth: 1920) == 1920)
    }

    @Test func anUnknownFrameRateCountsAsThirty() {
        #expect(TranscodeResolutionEstimate.width(cap: 4_000_000, outputCodec: "h264",
                                                  frameRate: nil, sourceWidth: nil) == 1280)
    }

    @Test func widthsReadAsTheNamesPeopleUse() {
        #expect(TranscodeResolutionEstimate.label(width: 3840) == "4K")
        #expect(TranscodeResolutionEstimate.label(width: 4096) == "4K")
        #expect(TranscodeResolutionEstimate.label(width: 2560) == "1440p")
        #expect(TranscodeResolutionEstimate.label(width: 1920) == "1080p")
        #expect(TranscodeResolutionEstimate.label(width: 1280) == "720p")
        #expect(TranscodeResolutionEstimate.label(width: 960) == "540p")
        #expect(TranscodeResolutionEstimate.label(width: 720) == "480p")
    }
}
