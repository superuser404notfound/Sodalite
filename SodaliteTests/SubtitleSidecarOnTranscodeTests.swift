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

    @Test func directPlayDeclaresOnlyExternalTracks() throws {
        let streams = [try stream(3, codec: "subrip"), try stream(9, codec: "srt", external: true)]
        let result = PlayerViewModel.externalSubtitleDescriptors(streams: streams, playMethod: .directPlay) {
            URL(string: "https://jf.example/sub/\($0.index).srt")
        }
        #expect(result.mapping.keys.sorted() == [9])
    }
}
