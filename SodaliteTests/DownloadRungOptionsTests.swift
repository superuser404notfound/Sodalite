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
}
