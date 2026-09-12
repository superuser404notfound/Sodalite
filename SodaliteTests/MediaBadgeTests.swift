import Testing
import Foundation
@testable import Sodalite

/// Sodalite#79: the pills a poster shows. Resolution comes from the item-level Width/Height that
/// every card query now carries; dynamic range and spatial audio only exist once MediaStreams have
/// been fetched, so the resolver must produce a partial answer without them rather than nothing.
struct MediaBadgeTests {

    private func video(width: Int?, height: Int? = nil, range: String? = nil,
                       dvProfile: Int? = nil) -> MediaStream {
        MediaStream(index: 0, type: .video, codec: "hevc", language: nil,
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: nil, height: height, width: width, channels: nil,
                    videoRange: nil, videoRangeType: range, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: dvProfile)
    }

    private func audio(codec: String, profile: String? = nil, channels: Int? = 6) -> MediaStream {
        MediaStream(index: 1, type: .audio, codec: codec, language: "eng",
                    displayTitle: nil, title: nil, isDefault: true, isForced: nil,
                    isExternal: nil, height: nil, width: nil, channels: channels,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: profile, bitRate: nil, dvProfile: nil)
    }

    // MARK: - Resolution

    @Test("a 3840-wide item reads as 4K")
    func uhdFromItemWidth() {
        #expect(MediaBadgeResolver.badges(width: 3840, height: 2160, streams: nil).resolution == .uhd)
    }

    @Test("a scope master is 4K by its width, its 1600 lines do not demote it")
    func uhdScopeByWidth() {
        #expect(MediaBadgeResolver.badges(width: nil, height: nil, streams: [video(width: 3840, height: 1600)]).resolution == .uhd)
    }

    @Test("1920x1080 reads as 1080p")
    func fullHD() {
        #expect(MediaBadgeResolver.badges(width: 1920, height: 1080, streams: nil).resolution == .fullHD)
    }

    @Test("1280x720 reads as 720p")
    func hd() {
        #expect(MediaBadgeResolver.badges(width: 1280, height: 720, streams: nil).resolution == .hd)
    }

    @Test("a 720x576 PAL rip reads as SD")
    func sd() {
        #expect(MediaBadgeResolver.badges(width: 720, height: 576, streams: nil).resolution == .sd)
    }

    @Test("a series poster with no width carries no resolution pill")
    func noWidthNoResolution() {
        #expect(MediaBadgeResolver.badges(width: nil, height: nil, streams: nil).resolution == nil)
    }

    @Test("the video stream's width wins over a stale item-level width")
    func streamWidthWins() {
        let badges = MediaBadgeResolver.badges(width: 1920, height: 1080, streams: [video(width: 3840, height: 2160)])
        #expect(badges.resolution == .uhd)
    }

    @Test("a 3240x2160 master is 4K: 2160 lines are 4K however narrow the frame is cropped")
    func uhdByHeightOnACroppedMaster() {
        #expect(MediaBadgeResolver.badges(width: 3240, height: 2160, streams: nil).resolution == .uhd)
    }

    @Test("a 1080p trailer sitting beside the feature does not decide the pill")
    func biggestVideoStreamWins() {
        let badges = MediaBadgeResolver.badges(
            width: nil, height: nil,
            streams: [video(width: 1920, height: 1080), video(width: 3840, height: 2160)])
        #expect(badges.resolution == .uhd)
    }

    // MARK: - Dynamic range

    @Test("a DV profile outranks the HDR10 layer it is built on")
    func dolbyVisionWinsOverHDR10() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [video(width: 3840, range: "DOVIWithHDR10", dvProfile: 7)])
        #expect(badges.dynamicRange == .dolbyVision)
    }

    @Test("HDR10+ is told apart from plain HDR10")
    func hdr10Plus() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [video(width: 3840, range: "HDR10Plus")])
        #expect(badges.dynamicRange == .hdr10Plus)
    }

    @Test("HDR10 is recognised")
    func hdr10() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [video(width: 3840, range: "HDR10")])
        #expect(badges.dynamicRange == .hdr10)
    }

    @Test("HLG is recognised")
    func hlg() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [video(width: 3840, range: "HLG")])
        #expect(badges.dynamicRange == .hlg)
    }

    @Test("SDR earns no pill, an empty corner is the statement")
    func sdrIsSilent() {
        let badges = MediaBadgeResolver.badges(width: 1920, height: 1080, streams: [video(width: 1920, range: "SDR")])
        #expect(badges.dynamicRange == nil)
    }

    @Test("an unknown range string earns no pill")
    func unknownRangeIsSilent() {
        let badges = MediaBadgeResolver.badges(width: 1920, height: 1080, streams: [video(width: 1920, range: "SOMETHINGNEW")])
        #expect(badges.dynamicRange == nil)
    }

    // MARK: - Audio

    @Test("Atmos is read out of the audio profile, the way the server derives it")
    func atmosFromProfile() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [audio(codec: "eac3", profile: "Dolby Digital+ with Dolby Atmos")])
        #expect(badges.audio == .atmos)
    }

    @Test("a TrueHD Atmos track is Atmos too")
    func atmosOnTrueHD() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [audio(codec: "truehd", profile: "TrueHD with Dolby Atmos", channels: 8)])
        #expect(badges.audio == .atmos)
    }

    @Test("DTS:X is told apart from Atmos")
    func dtsX() {
        let badges = MediaBadgeResolver.badges(width: 3840, height: 2160, streams: [audio(codec: "dts", profile: "DTS:X", channels: 8)])
        #expect(badges.audio == .dtsX)
    }

    @Test("plain 5.1 earns no audio pill, channel counts on every poster are noise")
    func plainSurroundIsSilent() {
        let badges = MediaBadgeResolver.badges(width: 1920, height: 1080, streams: [audio(codec: "ac3", profile: nil)])
        #expect(badges.audio == nil)
    }

    @Test("a spatial track anywhere in the list counts, not just the first")
    func spatialTrackFoundBehindAStereoDefault() {
        let badges = MediaBadgeResolver.badges(
            width: 3840, height: 2160,
            streams: [audio(codec: "aac", profile: nil, channels: 2),
                      audio(codec: "eac3", profile: "Dolby Digital+ with Dolby Atmos", channels: 6)])
        #expect(badges.audio == .atmos)
    }

    // MARK: - What the corner paints

    @Test("the pills read from the top down: resolution, picture, sound")
    func pillOrder() {
        let badges = MediaBadgeResolver.badges(
            width: 3840, height: 2160,
            streams: [video(width: 3840, range: "DOVI", dvProfile: 5),
                      audio(codec: "truehd", profile: "TrueHD with Dolby Atmos", channels: 8)])
        #expect(badges.pills == ["4K", "DV", "ATMOS"])
    }

    @Test("a plain 1080p SDR title paints one pill, not three empty ones")
    func pillsSkipWhatIsNotThere() {
        let badges = MediaBadgeResolver.badges(width: 1920, height: 1080, streams: [video(width: 1920, range: "SDR")])
        #expect(badges.pills == ["1080p"])
    }

    @Test("an item with nothing to say paints no corner at all")
    func noPills() {
        #expect(MediaBadgeResolver.badges(width: nil, height: nil, streams: nil).pills.isEmpty)
    }

    // MARK: - Pill geometry

    /// Measured on the tvOS simulator, not guessed at the TV: 0.06 of the tier's poster width puts
    /// the pill at 13.2pt on Apple TV, about half the 25pt card title next to it, and on the floor
    /// at 10pt on iPad and iPhone. It shipped at 0.09 and the reporter asked for a third off
    /// (Sodalite#79). A pill sized off its own card would be 21.6pt on a landscape card, so a row
    /// that mixes the two styles would wear two pill sizes.
    @Test("a landscape card carries the same pill as the poster beside it")
    func pillSizeIsTierWideNotCardWide() {
        let poster = PosterBadgeMetrics.fontSize(posterWidth: 220, scale: 1.0)
        #expect(poster > 13 && poster < 14, "tvOS pill lands at about half the card title")
        #expect(poster < LayoutMetrics.tv.landscapeSize.width * 0.06,
                "the pill reads the tier's poster width, not the card it sits on")
    }

    @Test("the pill follows the card-size setting")
    func pillFollowsCardScale() {
        let normal = PosterBadgeMetrics.fontSize(posterWidth: 220, scale: 1.0)
        let large = PosterBadgeMetrics.fontSize(posterWidth: 220, scale: 1.3)
        #expect(large > normal)
        #expect(abs(large - normal * 1.3) < 0.001)
    }

    @Test("the iPhone tier stays at a readable size rather than shrinking to nothing")
    func pillStaysReadableOnPhone() {
        #expect(PosterBadgeMetrics.fontSize(posterWidth: 120, scale: 1.0) >= 10)
        #expect(PosterBadgeMetrics.fontSize(posterWidth: 120, scale: 1.0) == 10,
                "below the TV the floor sets the pill, not the ratio")
        #expect(PosterBadgeMetrics.fontSize(posterWidth: 160, scale: 1.0) == 10)
    }

    // MARK: - Shape

    @Test("an item with nothing to say produces empty badges")
    func emptyBadges() {
        #expect(MediaBadgeResolver.badges(width: nil, height: nil, streams: nil).isEmpty)
    }

    @Test("resolution alone is not empty, so a card can paint before enrichment lands")
    func resolutionOnlyIsNotEmpty() {
        #expect(MediaBadgeResolver.badges(width: 3840, height: 2160, streams: nil).isEmpty == false)
    }
}
