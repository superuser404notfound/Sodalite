import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: under a transcode the video that plays is not the library's file. Jellyfin's stream
/// describes the file, so it may stand in for the engine only when the file is what arrives; a capped
/// session showed "H264 Main 10, 3840×2160, 17.4 Mbps" for a 1280×720 H.264 transcode.
struct StatsTranscodeVideoFactsTests {
    private func fileStream() throws -> MediaStream {
        try JSONDecoder().decode(
            MediaStream.self,
            from: Data(#"{"Index":0,"Type":"Video","Codec":"hevc","Profile":"Main 10","Width":3840,"Height":2160}"#.utf8))
    }

    @Test func theFileStandsInOnlyWhenTheFileIsWhatPlays() {
        #expect(StatsOverlayView.fileFactsDescribePlayback(playMethod: .directPlay))
        #expect(StatsOverlayView.fileFactsDescribePlayback(playMethod: .directStream))
        #expect(StatsOverlayView.fileFactsDescribePlayback(playMethod: nil))
        #expect(!StatsOverlayView.fileFactsDescribePlayback(playMethod: .transcode))
    }

    @Test func theEngineProfileWinsOverTheFiles() throws {
        #expect(StatsOverlayView.videoCodecLabel(
            engineName: "h264", engineProfile: "High", file: try fileStream()) == "H264 High")
    }

    @Test func aTranscodeCarriesNoProfileFromTheFile() {
        #expect(StatsOverlayView.videoCodecLabel(engineName: "h264", engineProfile: nil, file: nil) == "H264")
    }

    @Test func theFilesProfileStillFillsInForADirectPlay() throws {
        #expect(StatsOverlayView.videoCodecLabel(
            engineName: "hevc", engineProfile: nil, file: try fileStream()) == "HEVC Main 10")
    }

    @Test func theEngineResolutionWins() throws {
        #expect(StatsOverlayView.resolutionLabel(engineWidth: 1280, engineHeight: 720, file: try fileStream())
                == "1280×720")
    }

    @Test func aTranscodeWithoutAnEngineResolutionShowsNone() {
        #expect(StatsOverlayView.resolutionLabel(engineWidth: 0, engineHeight: 0, file: nil) == nil)
    }
}
