import AetherEngine
import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: a transcode renumbers the streams, so an embedded subtitle cannot be picked out of it
/// the way direct play does. Jellyfin serves every text subtitle stream as a file of its own, so on a
/// transcode an embedded text track is handed to the engine as a sidecar, like an external one. That
/// is what lets the skip-back window, the forced fallback and the picker work there at all; the old
/// server-extraction loader took up to two minutes and the skip-back window is thirty seconds.
struct SubtitleSidecarOnTranscodeTests {
    private func stream(_ index: Int, codec: String, external: Bool = false, forced: Bool = false) throws -> MediaStream {
        try JSONDecoder().decode(MediaStream.self, from: Data(
            #"{"Index":\#(index),"Type":"Subtitle","Codec":"\#(codec)","Language":"ger","IsExternal":\#(external),"IsForced":\#(forced)}"#.utf8))
    }

    @Test func anExternalTrackIsAlwaysASidecar() throws {
        #expect(PlayerViewModel.servedAsSidecar(try stream(7, codec: "subrip", external: true), playMethod: .directPlay))
        #expect(PlayerViewModel.servedAsSidecar(try stream(7, codec: "subrip", external: true), playMethod: .transcode))
    }

    @Test func anEmbeddedTextTrackIsASidecarOnlyUnderATranscode() throws {
        #expect(PlayerViewModel.servedAsSidecar(try stream(3, codec: "subrip"), playMethod: .transcode))
        #expect(PlayerViewModel.servedAsSidecar(try stream(3, codec: "ass"), playMethod: .transcode))
        #expect(!PlayerViewModel.servedAsSidecar(try stream(3, codec: "subrip"), playMethod: .directPlay))
        #expect(!PlayerViewModel.servedAsSidecar(try stream(3, codec: "subrip"), playMethod: .directStream))
    }

    /// Jellyfin can serve a bitmap track only by burning it in, which Sodalite never asks for.
    @Test func anEmbeddedBitmapTrackIsNeverASidecar() throws {
        #expect(!PlayerViewModel.servedAsSidecar(try stream(4, codec: "pgssub"), playMethod: .transcode))
        #expect(!PlayerViewModel.servedAsSidecar(try stream(4, codec: "dvdsub"), playMethod: .transcode))
    }

    @Test func aTranscodeDeclaresItsEmbeddedTextTracksToTheEngine() throws {
        let streams = [try stream(3, codec: "subrip", forced: true), try stream(4, codec: "pgssub"),
                       try stream(5, codec: "subrip"), try stream(9, codec: "srt", external: true)]
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: streams, playMethod: .transcode) {
            URL(string: "https://jf.example/sub/\($0.index).srt")
        }
        #expect(result.mapping.keys.sorted() == [3, 5, 9])
        #expect(result.descriptors.count == 3)
        #expect(result.descriptors.first?.isForced == true)
    }

    /// The engine names the native rendition from `name`, so Jellyfin's DisplayTitle must not reach
    /// it; the SDH flag rides along for the rendition's CHARACTERISTICS (AE#1050).
    @Test func aSidecarCarriesOnlyTheStreamTitleAndTheSDHFlag() throws {
        let titled = try JSONDecoder().decode(MediaStream.self, from: Data(
            #"{"Index":5,"Type":"Subtitle","Codec":"srt","Language":"eng","IsExternal":true,"Title":"CC","DisplayTitle":"CC - English - SRT - External"}"#.utf8))
        let untitled = try JSONDecoder().decode(MediaStream.self, from: Data(
            #"{"Index":6,"Type":"Subtitle","Codec":"srt","Language":"eng","IsExternal":true,"IsHearingImpaired":true,"DisplayTitle":"English - SDH - SRT - External"}"#.utf8))
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: [titled, untitled], playMethod: .directPlay) {
            URL(string: "https://jf.example/sub/\($0.index).srt")
        }
        #expect(result.descriptors.map(\.name) == ["CC", nil])
        #expect(result.descriptors.map(\.isHearingImpaired) == [false, true])
    }

    @Test func aSidecarWithoutLanguageKeepsTheDisplayTitle() throws {
        let bare = try JSONDecoder().decode(MediaStream.self, from: Data(
            #"{"Index":7,"Type":"Subtitle","Codec":"srt","IsExternal":true,"DisplayTitle":"Movie.forced - SRT - External"}"#.utf8))
        #expect(PlayerViewModel.sidecarName(bare) == "Movie.forced - SRT - External")
    }

    @Test func directPlayDeclaresOnlyExternalTracks() throws {
        let streams = [try stream(3, codec: "subrip"), try stream(9, codec: "srt", external: true)]
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: streams, playMethod: .directPlay) {
            URL(string: "https://jf.example/sub/\($0.index).srt")
        }
        #expect(result.mapping.keys.sorted() == [9])
    }
}
