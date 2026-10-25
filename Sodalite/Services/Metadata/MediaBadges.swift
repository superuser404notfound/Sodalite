import Foundation

/// What a card or a detail page can say about a copy without playing it: resolution, dynamic range,
/// spatial audio (Sodalite#79), and for the detail page the audio codec (Sodalite#145) and the
/// channel layout behind it (Sodalite#160).
///
/// Resolution rides on every card query (`Width` costs two ints out of the BaseItem row), the other
/// two only exist once `MediaStreams` have been fetched, so the resolver answers partially rather
/// than not at all: a poster paints "4K" immediately and grows "DV" when enrichment lands.
struct MediaBadges: Equatable, Sendable {

    /// Raw values are the pill text. Brand shorthand and line counts, not localised: "4K" is "4K"
    /// in every one of the 26 catalogs.
    enum Resolution: String, Sendable {
        case uhd = "4K"
        case fullHD = "1080p"
        case hd = "720p"
        case sd = "SD"
    }

    enum DynamicRange: String, Sendable {
        case dolbyVision = "DV"
        /// A Dolby Vision file whose base layer also carries ST 2094-40 (Sodalite#211). One pill,
        /// not two: both name the same fact, how the picture looks.
        case dolbyVisionHDR10Plus = "DV HDR10+"
        case hdr10Plus = "HDR10+"
        case hdr10 = "HDR10"
        case hlg = "HLG"
    }

    enum Audio: String, Sendable {
        case atmos = "ATMOS"
        case dtsX = "DTS:X"
    }

    var resolution: Resolution?
    var dynamicRange: DynamicRange?
    var audio: Audio?
    /// Brand shorthand for the best audio track's codec family ("DD+", "TrueHD", "DTS-HD").
    /// Detail pages only (Sodalite#145): a codec under every poster in a grid is noise, which is why
    /// `pills` leaves it out, but on the one page that describes one title it is the fact the
    /// spatial pill alone cannot give.
    var audioCodec: String?
    /// How big the bed of the same track is ("2.0", "5.1", "7.1", "6ch"), for the detail page's
    /// last pill when there is no spatial format to name (Sodalite#160).
    ///
    /// Numeric layout notation rather than `TechFacts.channelLayout`'s "Stereo": the pill row is
    /// unlocalised brand shorthand in all 26 catalogs, and the tech section further down the page
    /// is where the friendlier wording belongs.
    var channelLayout: String?

    var isEmpty: Bool { detailPills.isEmpty }

    /// Top to bottom in the poster corner: what it is, how it looks, how it sounds. Absent facts
    /// leave no gap, an empty slot would read as something still loading.
    var pills: [String] {
        [resolution?.rawValue, dynamicRange?.rawValue, audio?.rawValue].compactMap { $0 }
    }

    /// Left to right on a detail page's metadata line (Sodalite#145): what it is, how it looks, what
    /// the sound is, how big the sound is. Same four facts the poster corner draws from, one richer,
    /// and deliberately resolved by the same code so a card saying DV can never sit above a page
    /// saying HDR10.
    ///
    /// The last pill answers one question with whichever of two facts says more about it: a spatial
    /// format when the track has one, the channel layout otherwise (Sodalite#160). Never both, the
    /// bed of an Atmos track is the fact its name already carries.
    var detailPills: [String] {
        [resolution?.rawValue, dynamicRange?.rawValue, audioCodec, audio?.rawValue ?? channelLayout]
            .compactMap { $0 }
    }

    /// What `HDR10PlusProbeStore` found (AE#579), applied to the badge the container produced.
    ///
    /// One-directional, like the engine pass it comes from: it can only ever raise HDR10 to HDR10+.
    /// A Dolby Vision badge stays, because it already describes the layer the panel will present,
    /// and nothing without an HDR10 base layer is touched.
    func upgradedToHDR10Plus() -> MediaBadges {
        guard dynamicRange == .hdr10 else { return self }
        var upgraded = self
        upgraded.dynamicRange = .hdr10Plus
        return upgraded
    }
}

enum MediaBadgeResolver {

    /// `width`/`height` are the item-level geometry; `streams` is nil until the badge store has
    /// enriched the id.
    static func badges(width: Int?, height: Int?, streams: [MediaStream]?) -> MediaBadges {
        // Largest frame wins, not the first stream: a multi-version item (or a trailer the server
        // filed as an alternate version) hands back more than one video track, and the pill should
        // describe the best copy on the shelf rather than whichever one came back first.
        let video = streams?
            .filter { $0.type == .video }
            .max { area($0) < area($1) }
        let audio = bestAudio(streams)
        return MediaBadges(
            resolution: resolution(width: video?.width ?? width, height: video?.height ?? height),
            dynamicRange: dynamicRange(video),
            audio: spatial(audio),
            audioCodec: codecLabel(audio),
            channelLayout: channelLayout(audio)
        )
    }

    private static func area(_ stream: MediaStream) -> Int {
        (stream.width ?? 0) * (stream.height ?? 0)
    }

    /// Either edge can carry the class, because either one can be cropped away. A 3840x1600 scope
    /// master is 4K by its width; a 3240x2160 open-matte master is 4K by its 2160 lines, and judging
    /// it on width alone called it 1080p (found on device, 2026-08-24).
    private static func resolution(width: Int?, height: Int?) -> MediaBadges.Resolution? {
        let w = width ?? 0
        let h = height ?? 0
        guard w > 0 || h > 0 else { return nil }
        if w >= 3400 || h >= 1900 { return .uhd }
        if w >= 1800 || h >= 1000 { return .fullHD }
        if w >= 1200 || h >= 680  { return .hd }
        return .sd
    }

    private static func dynamicRange(_ video: MediaStream?) -> MediaBadges.DynamicRange? {
        guard let video else { return nil }
        let range = video.videoRangeType?.uppercased()
        switch range {
        case "DOVIWITHHDR10PLUS", "DOVIWITHELHDR10PLUS":         return .dolbyVisionHDR10Plus
        case _ where video.dvProfile != nil:                    return .dolbyVision
        case "HDR10PLUS":                                       return .hdr10Plus
        case "HDR10":                                           return .hdr10
        case "HLG":                                             return .hlg
        case "DOVI", "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR", "DOVIWITHEL":
            return .dolbyVision
        default:                                                return nil
        }
    }

    /// The track both audio pills describe. Ranked rather than taken in file order, because the
    /// track a file leads with is regularly the small one: a stereo AAC default sitting in front of
    /// the TrueHD Atmos master would otherwise have the page say AAC while the poster above it says
    /// ATMOS.
    ///
    /// Ranked by format first (spatial, then lossless, then lossy), the reporter's own three tiers
    /// (Sodalite#145), then by width, then by bitrate. Format ahead of width on purpose: a 5.1
    /// DTS-HD master outranks a 7.1 lossy track, which is the judgement the pill exists to make.
    /// The first of two equal tracks wins, so the order is stable.
    private static func bestAudio(_ streams: [MediaStream]?) -> MediaStream? {
        streams?
            .filter { $0.type == .audio }
            .max { rank($0) < rank($1) }
    }

    private static func rank(_ stream: MediaStream) -> (Int, Int, Int) {
        let tier = spatial(stream) != nil ? 2 : (isLossless(stream) ? 1 : 0)
        return (tier, stream.channels ?? 0, stream.bitRate ?? 0)
    }

    /// Spatial formats only. The server derives its own `AudioSpatialFormat` from exactly this
    /// string, so reading `profile` keeps the pill working on servers too old to send that field.
    private static func spatial(_ stream: MediaStream?) -> MediaBadges.Audio? {
        guard let profile = stream?.profile else { return nil }
        if profile.localizedCaseInsensitiveContains("Dolby Atmos") { return .atmos }
        if profile.localizedCaseInsensitiveContains("DTS:X") { return .dtsX }
        return nil
    }

    /// Whether the track keeps every bit of the master. DTS is the one that cannot be read off the
    /// codec: `dts` covers everything from a 768 kbps core to DTS-HD MA, and only the profile says
    /// which, so a DTS without a Master Audio profile counts as lossy.
    private static func isLossless(_ stream: MediaStream) -> Bool {
        let codec = (stream.codec ?? "").lowercased()
        if codec.hasPrefix("pcm") { return true }
        switch codec {
        case "truehd", "mlp", "flac", "alac", "wmalossless":
            return true
        case "dts", "dca":
            return stream.profile?.localizedCaseInsensitiveContains("MA") == true
        default:
            return false
        }
    }

    /// Brand shorthand rather than the server's codec string: "eac3" names a file, "DD+" names what
    /// is printed on the case the disc came in. Unmapped codecs fall through uppercased, so a format
    /// nobody anticipated still gets a pill instead of a hole.
    private static func codecLabel(_ stream: MediaStream?) -> String? {
        guard let raw = stream?.codec?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("pcm") { return "PCM" }
        if raw.hasPrefix("wma") { return "WMA" }
        switch raw {
        case "aac", "aac_latm": return "AAC"
        case "ac3":             return "DD"
        case "eac3":            return "DD+"
        case "ac4":             return "AC-4"
        case "truehd", "mlp":   return "TrueHD"
        case "dts", "dca":      return dtsLabel(stream)
        case "flac":            return "FLAC"
        case "alac":            return "ALAC"
        case "mp3":             return "MP3"
        case "mp2":             return "MP2"
        case "opus":            return "Opus"
        case "vorbis":          return "Vorbis"
        default:                return raw.uppercased()
        }
    }

    /// The bed of the track the codec pill describes (Sodalite#160). Only the counts whose layout
    /// is unambiguous get named: 3 channels is 2.1 as often as 3.0 and 10 can be 9.1 or 7.1.2, and
    /// Jellyfin sends a count, not a layout, so those fall back to "\(n)ch" rather than guessing a
    /// speaker arrangement the file may not have.
    private static func channelLayout(_ stream: MediaStream?) -> String? {
        guard let channels = stream?.channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// DTS:X is carried inside DTS-HD, so it names the carrier here and takes its own pill next to
    /// it, rather than spelling "DTS" twice across two pills.
    private static func dtsLabel(_ stream: MediaStream?) -> String {
        let profile = stream?.profile ?? ""
        if profile.localizedCaseInsensitiveContains("DTS-HD")
            || profile.localizedCaseInsensitiveContains("DTS:X") { return "DTS-HD" }
        return "DTS"
    }
}
