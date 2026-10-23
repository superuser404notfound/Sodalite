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
    @Test func aUserWithoutVideoTranscodingIsOfferedOnlyTheOriginal() throws {
        let options = DownloadRungOption.options(sourceBitrate: 29_000_000, sourceSize: 5_570_000_000,
                                                 runtimeTicks: 15_600_000_000, canTranscodeVideo: false)
        #expect(options.map(\.quality) == [.original])
        #expect(options.first?.estimatedBytes == 5_570_000_000)

        let remux = try source("remux", name: "Remux", height: 1080, bitrate: 30_000_000, size: 30_000)
        let uhd = try source("uhd", name: "UHD", height: 2160, bitrate: 20_000_000, size: 9_000)
        let versions = DownloadRungOption.options(versions: [remux, uhd], selected: uhd,
                                                  runtimeTicks: 36_000_000_000, canTranscodeVideo: false)
        #expect(versions.map(\.quality) == [.original, .original])
    }

    private func source(_ id: String, name: String, height: Int, bitrate: Int, size: Int64) throws -> MediaSource {
        try JSONDecoder().decode(MediaSource.self, from: Data(#"""
            {"Id":"\#(id)","Name":"\#(name)","Size":\#(size),"Bitrate":\#(bitrate),
             "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":\#(height * 16 / 9),"Height":\#(height)}]}
            """#.utf8))
    }

    @Test func everyVersionIsAnOriginalAndTheRungsFollowTheSelectedOne() throws {
        let remux = try source("remux", name: "Remux", height: 1080, bitrate: 30_000_000, size: 30_000)
        let uhd = try source("uhd", name: "UHD", height: 2160, bitrate: 3_000_000, size: 9_000)
        let options = DownloadRungOption.options(versions: [remux, uhd], selected: uhd, runtimeTicks: 36_000_000_000)
        #expect(options.map(\.quality) == [.original, .original, .mbps2])
        #expect(options.map(\.source?.id) == ["uhd", "remux", nil])
        #expect(options.map(\.estimatedBytes).prefix(2) == [9_000, 30_000])
        #expect(Set(options.map(\.id)).count == options.count)
    }

    @Test func versionLabelWithoutSizeDropsOnlyTheSize() throws {
        let uhd = try source("uhd", name: "UHD", height: 2160, bitrate: 3_000_000, size: 9_000_000_000)
        #expect(uhd.versionLabel(includingSize: false) == "UHD · 4K · H264")
        #expect(uhd.versionLabel.hasPrefix("UHD · 4K · H264 · "))
    }
}
