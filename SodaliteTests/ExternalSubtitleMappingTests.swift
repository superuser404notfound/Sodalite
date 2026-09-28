import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// AE#88 adoption: external Jellyfin subtitle streams become LoadOptions.externalSubtitles
/// declarations plus a streamIndex -> engine-track-id map (the engine guarantees
/// externalSubtitleTrackIDBase + array index for load-declared tracks).
@MainActor
struct ExternalSubtitleMappingTests {

    private func stream(index: Int, external: Bool, codec: String? = "srt",
                        lang: String? = "de", title: String? = nil,
                        forced: Bool? = nil) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: forced,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    @Test("the subtitle route asks for the extension Jellyfin serves, not the codec name")
    func subtitleRouteFormat() {
        // ffprobe names two of these differently from the file extension the route expects, and
        // Jellyfin has no writer registered under the codec name, so the track never arrives.
        #expect(JellyfinPlaybackService.subtitleRouteFormat(forCodec: "subrip") == "srt")
        #expect(JellyfinPlaybackService.subtitleRouteFormat(forCodec: "webvtt") == "vtt")
        #expect(JellyfinPlaybackService.subtitleRouteFormat(forCodec: "ass") == "ass")
        #expect(JellyfinPlaybackService.subtitleRouteFormat(forCodec: "srt") == "srt")
        #expect(JellyfinPlaybackService.subtitleRouteFormat(forCodec: "vtt") == "vtt")
    }

    @Test("external streams map to base-offset ids in declaration order; embedded are skipped")
    func mappingOrder() {
        let streams = [stream(index: 2, external: false),
                       stream(index: 5, external: true),
                       stream(index: 9, external: true)]
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: streams, playMethod: .directPlay) { s in
            URL(string: "https://jf/subs/\(s.index).srt")
        }
        #expect(result.descriptors.count == 2)
        #expect(result.mapping[5] == AetherEngine.externalSubtitleTrackIDBase)
        #expect(result.mapping[9] == AetherEngine.externalSubtitleTrackIDBase + 1)
        #expect(result.mapping[2] == nil)
    }

    @Test("a stream whose URL cannot be built is skipped and does not shift later ids")
    func urlFailureSkips() {
        let streams = [stream(index: 5, external: true), stream(index: 9, external: true)]
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: streams, playMethod: .directPlay) { s in
            s.index == 5 ? nil : URL(string: "https://jf/subs/9.srt")
        }
        #expect(result.descriptors.count == 1)
        #expect(result.mapping[5] == nil)
        #expect(result.mapping[9] == AetherEngine.externalSubtitleTrackIDBase)
    }

    @Test("descriptor carries language, forced flag, title, and codec hint")
    func descriptorMetadata() throws {
        let streams = [stream(index: 5, external: true, codec: "ass", lang: "de",
                              title: "German (SDH)", forced: true)]
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: streams, playMethod: .directPlay) { _ in
            URL(string: "https://jf/subs/5.ass")
        }
        let d = try #require(result.descriptors.first)
        #expect(d.language == "de")
        #expect(d.isForced)
        #expect(d.name == "German (SDH)")
        #expect(d.formatHint == "ass")
    }
}
