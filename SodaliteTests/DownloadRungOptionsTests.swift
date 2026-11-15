import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadRungOptionsTests {
    @Test func originalPlusBitingRungsBestFirst() {
        let options = DownloadRungOption.options(sourceBitrate: 15_000_000, sourceSize: 10_000, runtimeTicks: 36_000_000_000)
        #expect(options.map(\.quality) == [.original, .mbps10, .mbps4, .mbps2])
        #expect(options.first { $0.quality == .original }?.estimatedBytes == 10_000)
        #expect(options.first { $0.quality == .mbps2 }?.estimatedBytes == Int64(900_000_000))
    }

    @Test func onlyRungsThatBiteAreOffered() {
        let options = DownloadRungOption.options(sourceBitrate: 3_000_000, sourceSize: 10, runtimeTicks: nil)
        #expect(options.map(\.quality) == [.original, .mbps2])
    }

    /// Sodalite#202: the server would copy the video under every rung, so their sizes would be fiction.
    @Test func aUserWithoutVideoTranscodingIsOfferedOnlyTheOriginal() {
        let options = DownloadRungOption.options(sourceBitrate: 29_000_000, sourceSize: 5_570_000_000,
                                                 runtimeTicks: 15_600_000_000, canTranscodeVideo: false)
        #expect(options.map(\.quality) == [.original])
        #expect(options.first?.estimatedBytes == 5_570_000_000)
    }

    private func source(_ id: String, name: String, height: Int, bitrate: Int, size: Int64) throws -> MediaSource {
        try JSONDecoder().decode(MediaSource.self, from: Data(#"""
            {"Id":"\#(id)","Name":"\#(name)","Size":\#(size),"Bitrate":\#(bitrate),
             "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":\#(height * 16 / 9),"Height":\#(height)}]}
            """#.utf8))
    }

    /// Sodalite#200 follow-up (AJPerez): the dialog offers the rungs of the version the page has
    /// selected, sized from that version, not one Original per version with unnamed rungs below.
    @Test func theRungsAreSizedFromTheSelectedVersion() throws {
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"""
            {"Id":"m","Name":"M","Type":"Movie","RunTimeTicks":36000000000,"MediaSources":[
             {"Id":"remux","Name":"Remux","Size":30000,"Bitrate":30000000},
             {"Id":"uhd","Name":"UHD","Size":9000,"Bitrate":3000000}]}
            """#.utf8))
        let facts = DownloadTarget.item(item, sourceID: "uhd").facts(order: .quality)
        let options = DownloadRungOption.options(sourceBitrate: facts.bitrate, sourceSize: facts.size, runtimeTicks: facts.runtimeTicks)
        #expect(options.map(\.quality) == [.original, .mbps2])
        #expect(options.first?.estimatedBytes == 9_000)
    }

    @Test func versionLabelWithoutSizeDropsOnlyTheSize() throws {
        let uhd = try source("uhd", name: "UHD", height: 2160, bitrate: 3_000_000, size: 9_000_000_000)
        #expect(uhd.versionLabel(includingSize: false) == "UHD · 4K · H264")
        #expect(uhd.versionLabel.hasPrefix("UHD · 4K · H264 · "))
    }
}
