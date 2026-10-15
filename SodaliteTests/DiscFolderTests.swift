import Testing
import Foundation
@testable import Sodalite

/// Sodalite#185: Jellyfin reports a BDMV or VIDEO_TS folder through `VideoType`, and answers every
/// request for its original bytes with an ffmpeg session.
struct DiscFolderTests {

    private func playbackSource(videoType: String?) throws -> PlaybackMediaSource {
        var fields = [#""Id":"s1""#, #""Container":"ts""#]
        if let videoType { fields.append(#""VideoType":"\#(videoType)""#) }
        return try JSONDecoder().decode(PlaybackMediaSource.self,
                                        from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    @Test("Blu-ray and DVD folders are disc folders", arguments: ["BluRay", "Dvd"])
    func folders(videoType: String) throws {
        #expect(try playbackSource(videoType: videoType).isDiscFolder)
    }

    @Test("a plain file, an ISO and a server that omits the field are not",
          arguments: ["VideoFile", "Iso", nil] as [String?])
    func notFolders(videoType: String?) throws {
        #expect(try !playbackSource(videoType: videoType).isDiscFolder)
    }
}
