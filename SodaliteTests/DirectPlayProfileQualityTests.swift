import Testing
import Foundation
@testable import Sodalite

@MainActor
struct DirectPlayProfileQualityTests {
    private func videoTranscoding(_ profile: [String: Any]) -> [String: Any] {
        let list = profile["TranscodingProfiles"] as? [[String: Any]] ?? []
        return list.first { $0["Type"] as? String == "Video" } ?? [:]
    }

    @Test func withoutACapTheCeilingStaysAt200() {
        let profile = DirectPlayProfile.baseProfile()
        #expect(profile["MaxStreamingBitrate"] as? Int == 200_000_000)
        #expect(profile["MaxStaticBitrate"] as? Int == 200_000_000)
    }

    /// Only the streaming ceiling moves. The direct-play lists stay whole, so a file under the cap
    /// still direct-plays: the cap is what bites, not a narrower codec list.
    @Test func aCapLowersOnlyTheStreamingCeiling() {
        let capped = DirectPlayProfile.baseProfile(maxStreamingBitrate: 4_000_000)
        let base = DirectPlayProfile.baseProfile()
        #expect(capped["MaxStreamingBitrate"] as? Int == 4_000_000)
        #expect(capped["MaxStaticBitrate"] as? Int == 200_000_000)
        #expect(NSDictionary(dictionary: ["d": capped["DirectPlayProfiles"] as Any])
                == NSDictionary(dictionary: ["d": base["DirectPlayProfiles"] as Any]))
    }

    /// AVFoundation plays HEVC over HLS only in fMP4, so the segments must be mp4, not ts.
    @Test func videoTranscodesAreHLSInFragmentedMP4() {
        let video = videoTranscoding(DirectPlayProfile.baseProfile())
        #expect(video["Protocol"] as? String == "hls")
        #expect(video["Container"] as? String == "mp4")
        #expect(video["Context"] as? String == "Streaming")
        let audio = Set((video["AudioCodec"] as? String ?? "").split(separator: ",").map(String.init))
        #expect(audio == ["aac", "ac3", "eac3"])
    }

    /// Live keeps its own progressive TS profile; a VOD change must not leak into it.
    @Test func liveKeepsItsOwnTranscodingProfile() {
        let video = videoTranscoding(DirectPlayProfile.liveProfile())
        #expect(video["Protocol"] as? String == "http")
        #expect(video["Container"] as? String == "ts")
    }

    @Test func theBodyMirrorsTheCapForTheServer() {
        let body = JellyfinPlaybackService.playbackInfoBody(
            profile: DirectPlayProfile.baseProfile(maxStreamingBitrate: 10_000_000),
            maxStreamingBitrate: 10_000_000, enableDirectPlay: true)
        #expect(body["MaxStreamingBitrate"] as? Int == 10_000_000)
        #expect(body["AudioStreamIndex"] == nil)
        #expect(body["EnableDirectPlay"] == nil)
        #expect(body["DeviceProfile"] != nil)
    }

    /// Live sends its cap as a query item; a body value could contradict the 12 Mbit/s re-encode pass.
    @Test func theBodyCarriesNoCapWhenNoneIsGiven() {
        let body = JellyfinPlaybackService.playbackInfoBody(
            profile: DirectPlayProfile.liveProfile(), maxStreamingBitrate: nil, enableDirectPlay: true)
        #expect(body["MaxStreamingBitrate"] == nil)
    }

    /// A capped transcode muxes one audio stream; this names which one (final review #4).
    @Test func theBodyNamesTheAudioStreamWhenGiven() {
        let body = JellyfinPlaybackService.playbackInfoBody(
            profile: [:], maxStreamingBitrate: 4_000_000, audioStreamIndex: 2, enableDirectPlay: true)
        #expect(body["AudioStreamIndex"] as? Int == 2)
    }

    /// Sodalite draws every subtitle itself. A server-chosen subtitle on a capped transcode is burned
    /// in, and Jellyfin first extracts every subtitle from the whole file to do it: a minute on a
    /// 15 GB remux, long after AVPlayer gave up (device log 2026-09-28), and a doubled line if it
    /// ever arrives. So a VOD request names no subtitle stream at all.
    @Test func aVODRequestAsksTheServerForNoSubtitle() {
        let body = JellyfinPlaybackService.vodPlaybackInfoBody(
            profile: DirectPlayProfile.baseProfile(maxStreamingBitrate: 4_000_000), audioStreamIndex: 1)
        #expect(body["SubtitleStreamIndex"] as? Int == -1)
        #expect(body["MaxStreamingBitrate"] as? Int == 4_000_000)
        #expect(body["AudioStreamIndex"] as? Int == 1)
        #expect(body["EnableDirectPlay"] == nil)
    }

    /// Live keeps the server's subtitle choice; its path was not part of this change.
    @Test func aLiveBodyNamesNoSubtitleStream() {
        let body = JellyfinPlaybackService.playbackInfoBody(
            profile: DirectPlayProfile.liveProfile(), maxStreamingBitrate: nil, enableDirectPlay: true)
        #expect(body["SubtitleStreamIndex"] == nil)
    }

    @Test func theBodyOmitsDirectPlayOnlyWhenFalse() {
        let body = JellyfinPlaybackService.playbackInfoBody(profile: [:], maxStreamingBitrate: nil,
                                                            enableDirectPlay: false)
        #expect(body["EnableDirectPlay"] as? Bool == false)
        #expect(body["MaxStreamingBitrate"] == nil)
    }
}
