import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: a Jellyfin transcode drops the stream metadata (`-map_metadata -1`) and its master has no
/// audio group, so the engine cannot name the language being heard there. Everything that reads it (the
/// skip-back window, the forced fallback, the subtitle auto-pick) then found nothing. The transcode URL
/// names the Jellyfin audio stream it carries, and the source knows that stream's language.
struct TranscodeAudioLanguageTests {
    private func streams() throws -> [MediaStream] {
        try JSONDecoder().decode([MediaStream].self, from: Data(#"""
        [{"Index":0,"Type":"Video","Codec":"hevc"},
         {"Index":1,"Type":"Audio","Codec":"eac3","Language":"ger"},
         {"Index":2,"Type":"Audio","Codec":"eac3","Language":"eng"},
         {"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"ger"}]
        """#.utf8))
    }

    @Test func theTranscodeURLNamesTheStreamBeingHeard() throws {
        let url = "/videos/x/master.m3u8?MediaSourceId=a&AudioStreamIndex=2&VideoBitrate=3744000"
        #expect(PlayerViewModel.transcodeAudioLanguage(transcodingURL: url, streams: try streams()) == "eng")
    }

    @Test func aURLWithoutAnAudioIndexNamesNothing() throws {
        #expect(PlayerViewModel.transcodeAudioLanguage(
            transcodingURL: "/videos/x/master.m3u8?VideoBitrate=1", streams: try streams()) == nil)
        #expect(PlayerViewModel.transcodeAudioLanguage(transcodingURL: nil, streams: try streams()) == nil)
    }

    /// An index that names a subtitle or nothing is not an audio language.
    @Test func anIndexThatIsNoAudioStreamNamesNothing() throws {
        #expect(PlayerViewModel.transcodeAudioLanguage(
            transcodingURL: "/m.m3u8?AudioStreamIndex=3", streams: try streams()) == nil)
        #expect(PlayerViewModel.transcodeAudioLanguage(
            transcodingURL: "/m.m3u8?audiostreamindex=9", streams: try streams()) == nil)
    }
}
