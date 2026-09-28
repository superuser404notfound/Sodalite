import Foundation
import AetherEngine

/// Jellyfin device profile for AetherEngine on Apple TV. Engine demuxes
/// MKV/MP4/AVI/TS/VOB/3GP/M2TS/ASF via FFmpeg, dispatching to native AVPlayer HLS
/// (HEVC, H.264, AV1+HW) or SW pipeline (AV1 no-HW, VP9, MPEG-4 Part 2,
/// MPEG-2, VC-1); server transcodes only codecs outside this set. One
/// `baseProfile()` (HDR/SDR split lives at the engine `displayCapabilities`
/// level, not the server-facing profile; HDR direct-plays on SDR via VideoToolbox).
@MainActor
enum DirectPlayProfile {

    /// The VOD profile. `maxStreamingBitrate` is the viewer's rung (Sodalite#87); nil keeps the
    /// direct-play ceiling.
    static func current(maxStreamingBitrate: Int? = nil) -> [String: Any] {
        #if DEBUG
        let caps = AetherEngine.displayCapabilities
        print("[Profile] Display: HDR=\(caps.supportsHDR) DV=\(caps.supportsDolbyVision) HDR10=\(caps.supportsHDR10) HLG=\(caps.supportsHLG)")
        #endif
        return baseProfile(maxStreamingBitrate: maxStreamingBitrate)
    }

    static let directPlayCeilingBitrate = 200_000_000

    /// Live stream-copy ceiling: kept at the VOD direct-play ceiling so any
    /// broadcast H.264/HEVC stays under it and Jellyfin copies the bitstream.
    /// Doubles as the encoder target for genuinely incompatible channels (e.g.
    /// MPEG-2 OTA), which would need a separate per-codec re-encode cap.
    static let liveCopyCeilingBitrate = 200_000_000

    /// Bounded encoder target (re-encode) for channels whose source codec is
    /// NOT in liveProfile's VideoCodec list (Jellyfin reports
    /// VideoCodecNotSupported). MaxStreamingBitrate doubles as the encoder
    /// target, so probing at the 200 Mbps ceiling makes the server answer
    /// HTTP 500 (device-verified on "Infomercial"). 12 Mbps = sane 1080p H.264.
    static let liveReencodeCapBitrate = 12_000_000

    /// Live TV profile. Protocol=http/Container=ts: progressive MPEG-TS (not
    /// HLS) consumed by AetherEngine's AVIOReader; engine demuxes + dispatches
    /// every live codec with no server re-encode. Full copy codec list + high
    /// MaxStreamingBitrate keep Jellyfin stream-copying instead of downscaling.
    static func liveProfile() -> [String: Any] {
        var profile = current()
        profile["MaxStreamingBitrate"] = liveCopyCeilingBitrate
        profile["MaxStaticBitrate"] = liveCopyCeilingBitrate
        // VideoCodec = every engine-decodable codec MPEG-TS can legally carry.
        // Do NOT add av1/vp9/vp8: ffmpeg's mpegts muxer rejects them and
        // Jellyfin then answers HTTP 400 on every transcode URL, breaking all
        // non-DirectPlay channels (device-verified: NBC 1 400'd the moment
        // av1,vp9,vp8 were added). Such channels need a SEPARATE
        // TranscodingProfile (e.g. matroska); a codec outside this list reports
        // VideoCodecNotSupported and takes the 12 Mbps re-encode in loadLiveStream.
        profile["TranscodingProfiles"] = [
            [
                "Type": "Video",
                "Container": "ts",
                "Protocol": "http",
                "VideoCodec": "h264,hevc,mpeg2video,vc1,mpeg4",
                "AudioCodec": "aac,ac3,eac3,mp3,mp2",
                "Context": "Streaming",
            ],
        ] as [[String: Any]]
        return profile
    }

    // MARK: - Base profile

    static func baseProfile(maxStreamingBitrate: Int? = nil) -> [String: Any] {
        [
            "MaxStreamingBitrate": maxStreamingBitrate ?? directPlayCeilingBitrate,
            "MaxStaticBitrate": directPlayCeilingBitrate,
            "MusicStreamingTranscodingBitrate": 384_000,

            // VideoCodec list mirrors what FFmpegBuild compiles a decoder for,
            // not the engine dispatch table: since AetherEngine 6.18.0 the
            // engine routes every non-native codec to libavcodec, so the
            // question is no longer "does the table name it" but "can the
            // bundled build decode it". Listing them stops Jellyfin transcoding
            // XVID/DivX, MPEG-2 remuxes, VC-1 BD rips and qtrle screen grabs.
            // The msmpeg4 / wmv family arrived with FFmpegBuild 2.4.3, its own
            // container and the WMA decoders with 3.1.0, so asf / wmv sit in the
            // Container list and every WMA flavour in AudioCodec below. They move
            // together or not at all: a container offered without its audio codecs
            // is a film that direct-plays silently (the engine's bridge finds no
            // decoder for the id and serves the session video-only), which is a
            // worse answer than letting the server transcode.
            // DirectPlayProfileWMVTests pins that.
            // FFmpegBuild 3.2.0 does the same for Flash: the flv container was
            // always listed and a modern .flv (H.264 + AAC) direct-played on it,
            // while the legacy tail went to the server for a transcode. flv1
            // (Sorenson Spark) and the VP6 family below, plus Nellymoser,
            // ADPCM-SWF, Speex and FLV's G.711 / big-endian PCM, close it.
            // Requested in the Discord.
            "DirectPlayProfiles": [
                [
                    "Container": "mp4,m4v,mov,mkv,matroska,avi,mpegts,ts,m2ts,mts,3gp,3g2,vob,ogg,webm,flv,asf,wmv",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,vc1,qtrle,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,flv1,flv,vp6,vp6f,vp6a",
                    // DTS spelled every way Jellyfin reports it (dts/dca/dts-hd
                    // vary by build) so it won't transcode DTS-HD MA over a
                    // string mismatch. mp2 pairs with MPEG-2 (broadcast/VOB).
                    // aac_latm is its own ffprobe codec name, not a spelling of
                    // aac, and it is how DVB carries AAC on most European HD
                    // channels; the decoder has always been in the build, so
                    // leaving it out only ever made the server answer
                    // AudioCodecNotSupported for audio we decode natively.
                    // pcm_bluray is the same story for M2TS/Blu-ray LPCM.
                    // The PCM line covers FLV's shapes too: big-endian S16,
                    // unsigned 8-bit and G.711 A-law / mu-law. AudioCodecCompat
                    // already routed those ids to the bridge, but no decoder was
                    // compiled in before 3.2.0, so the bridge had nothing to open.
                    "AudioCodec": "aac,aac_latm,ac3,eac3,mp3,mp2,flac,opus,vorbis,alac,truehd,mlp,dts,dca,dts-hd,dtshd,pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be,pcm_u8,pcm_alaw,pcm_mulaw,pcm_bluray,wmav1,wmav2,wmapro,wmalossless,wmavoice,nellymoser,adpcm_swf,speex",
                ],
                [
                    "Container": "mp3,aac,m4a,m4b,flac,alac,wav,opus,ogg",
                    "Type": "Audio",
                ],
            ] as [[String: Any]],

            // A transcode is Jellyfin HLS, played by AVPlayer through the engine's nativeRemoteHLS
            // route, so a seek fetches segments instead of restarting a progressive encode. fMP4, not
            // TS: AVFoundation plays HEVC over HLS only in fMP4. av1 and vp9 are left out because
            // AVPlayer, which plays this route, does not decode them over HLS on every device
            // (Sodalite#87). HEVC first: Jellyfin encodes the first listed codec the server may encode
            // and moves hevc to the end itself when HEVC encoding is off, so this buys the better picture
            // per bit at the low rungs where allowed and changes nothing elsewhere.
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "mp4",
                    "Protocol": "hls",
                    "VideoCodec": "hevc,h264",
                    "AudioCodec": "aac,ac3,eac3",
                    "Context": "Streaming",
                ],
                [
                    "Type": "Audio",
                    "Container": "mp3",
                    "Protocol": "http",
                    "AudioCodec": "mp3",
                    "Context": "Streaming",
                ],
            ] as [[String: Any]],

            "ContainerProfiles": [] as [Any],
            "CodecProfiles": [] as [[String: Any]],
            "SubtitleProfiles": Self.subtitleProfiles,
        ]
    }

    // MARK: - Subtitles (shared)

    /// All formats delivered External (fetched as SRT via Jellyfin's subtitle
    /// API) so an "unsupported" subtitle codec never forces a video transcode.
    private static let subtitleProfiles: [[String: Any]] = [
        ["Format": "vtt", "Method": "External"],
        ["Format": "webvtt", "Method": "External"],
        ["Format": "srt", "Method": "External"],
        ["Format": "subrip", "Method": "External"],
        ["Format": "ass", "Method": "External"],
        ["Format": "ssa", "Method": "External"],
        ["Format": "pgssub", "Method": "External"],
        ["Format": "pgs", "Method": "External"],
        ["Format": "dvdsub", "Method": "External"],
        ["Format": "dvbsub", "Method": "External"],
    ]
}
