import Testing
import Foundation
@testable import Sodalite

/// Sodalite#255: a log has to say why subtitles came up at the start of a title. These pin the
/// wording, and above all that a track's forced flag shows, since a full track tagged forced looks
/// like any other in the menu.
struct SubtitleAutoPickLogTests {

    private func stream(index: Int, lang: String? = "eng", codec: String? = "subrip",
                        title: String? = nil, isDefault: Bool? = nil, forced: Bool? = nil,
                        external: Bool? = nil, sdh: Bool? = nil) -> MediaStream {
        var stream = MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                                 displayTitle: nil, title: title, isDefault: isDefault, isForced: forced,
                                 isExternal: external, height: nil, width: nil, channels: nil,
                                 videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                                 realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
        stream.isHearingImpaired = sdh
        return stream
    }

    @Test("a track names language, codec, title and every flag the rules read")
    func describesFlags() {
        let track = stream(index: 3, title: "English", isDefault: true, forced: true, external: true, sdh: true)
        #expect(SubtitleAutoPickLog.describe(track) == "#3 eng subrip \"English\" [forced,sdh,default,external]")
    }

    @Test("a plain track without language or codec still reads")
    func describesBareTrack() {
        #expect(SubtitleAutoPickLog.describe(stream(index: 5, lang: nil, codec: nil, title: ""))
                == "#5 und ?")
    }

    @Test("a remembered pick says where it came from")
    func rememberedLines() {
        let streams = [stream(index: 4)]
        #expect(SubtitleAutoPickLog.rememberedLine(streamIndex: 4, streams: streams, source: .trackMemory)
                == "[Subtitles] auto pick: #4 eng subrip, remembered for this title")
        #expect(SubtitleAutoPickLog.rememberedLine(streamIndex: nil, streams: streams, source: .detailPage)
                == "[Subtitles] auto pick: off, picked on the detail page")
        #expect(SubtitleAutoPickLog.rememberedLine(streamIndex: 9, streams: streams, source: .trackMemory)
                == "[Subtitles] auto pick: #9, remembered for this title")
    }

    @Test("each rule outcome has its own line")
    func ruleLines() {
        let english = stream(index: 2)
        #expect(SubtitleAutoPickLog.ruleLine(.preferredLanguage("eng", picked: english))
                == "[Subtitles] auto pick: #2 eng subrip, Preferred Subtitle Language eng")
        #expect(SubtitleAutoPickLog.ruleLine(.preferredLanguage("ger", picked: nil))
                == "[Subtitles] auto pick: nothing, no ger track for Preferred Subtitle Language")
        #expect(SubtitleAutoPickLog.ruleLine(.foreignAudio(audio: "jpn", preferred: "en", picked: english))
                == "[Subtitles] auto pick: #2 eng subrip, audio jpn is foreign to en")
        #expect(SubtitleAutoPickLog.ruleLine(.foreignAudio(audio: "jpn", preferred: "en", picked: nil))
                == "[Subtitles] auto pick: nothing, audio jpn is foreign to en but no en track")
        #expect(SubtitleAutoPickLog.ruleLine(.audioNotForeign(audio: "eng", preferred: "en"))
                == "[Subtitles] auto pick: nothing, audio eng is not foreign to en")
        #expect(SubtitleAutoPickLog.ruleLine(.audioNotForeign(audio: nil, preferred: "en"))
                == "[Subtitles] auto pick: nothing, audio language unknown")
        #expect(SubtitleAutoPickLog.ruleLine(.foreignRuleOff)
                == "[Subtitles] auto pick: nothing, Subtitles for foreign audio is off")
        #expect(SubtitleAutoPickLog.ruleLine(.noPreferredAudio)
                == "[Subtitles] auto pick: nothing, no preferred audio language")
    }

    @Test("the forced fallback names the track and its forced flag")
    func forcedFallbackLines() {
        let streams = [stream(index: 6, title: "English", forced: true),
                       stream(index: 7, codec: "hdmv_pgs_subtitle")]
        #expect(SubtitleAutoPickLog.forcedFallbackLine(.forcedTrack(streamIndex: 6), streams: streams,
                                                       audioLanguage: "eng")
                == "[Subtitles] forced fallback: whole track #6 eng subrip \"English\" [forced], audio eng")
        #expect(SubtitleAutoPickLog.forcedFallbackLine(.cueFilter(streamIndex: 7), streams: streams,
                                                       audioLanguage: nil)
                == "[Subtitles] forced fallback: forced cues of #7 eng hdmv_pgs_subtitle, audio unknown")
        #expect(SubtitleAutoPickLog.forcedFallbackLine(.none, streams: streams, audioLanguage: "eng")
                == "[Subtitles] forced fallback: none, audio eng")
    }
}
