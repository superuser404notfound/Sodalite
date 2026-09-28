import Testing
@testable import Sodalite

@Suite("Streaming quality rungs")
struct StreamingQualityTests {
    private func reading(metered: Bool) -> NetworkPathSnapshot.Reading {
        NetworkPathSnapshot.Reading(isSatisfied: true, usesLocalInterface: !metered,
                                    hasLocalInterface: !metered, isMetered: metered)
    }

    @Test func theRungsAreOrderedFromOriginalDown() {
        #expect(StreamingQuality.allCases == [.original, .mbps40, .mbps20, .mbps10, .mbps4, .mbps2])
        #expect(StreamingQuality.allCases.map(\.maxStreamingBitrate)
                == [nil, 40_000_000, 20_000_000, 10_000_000, 4_000_000, 2_000_000])
    }

    @Test func originalNeverBites() {
        #expect(!StreamingQuality.original.bites(sourceBitrate: 90_000_000))
    }

    @Test func aRungBitesOnlyAboveItsCap() {
        #expect(StreamingQuality.mbps10.bites(sourceBitrate: 12_000_000))
        #expect(!StreamingQuality.mbps10.bites(sourceBitrate: 6_000_000))
        #expect(!StreamingQuality.mbps10.bites(sourceBitrate: 10_000_000))
    }

    /// No bitrate from the server means we cannot tell, and the honest label is the cautious one.
    @Test func anUnknownSourceBitrateCountsAsBiting() {
        #expect(StreamingQuality.mbps4.bites(sourceBitrate: nil))
    }

    @Test func wifiTakesTheWifiRung() {
        #expect(StreamingQuality.resolve(wifi: .original, cellular: .mbps4,
                                         reading: reading(metered: false), platformHasCellular: true) == .original)
    }

    @Test func aMeteredPathTakesTheCellularRung() {
        #expect(StreamingQuality.resolve(wifi: .original, cellular: .mbps4,
                                         reading: reading(metered: true), platformHasCellular: true) == .mbps4)
    }

    @Test func anUnknownPathCountsAsWifi() {
        #expect(StreamingQuality.resolve(wifi: .mbps20, cellular: .mbps2,
                                         reading: nil, platformHasCellular: true) == .mbps20)
    }

    @Test func theHintNamesTheReencodeOnlyWhenItBites() {
        #expect(StreamingQuality.mbps10.pickerHint(sourceBitrate: 30_000_000) != nil)
        #expect(StreamingQuality.mbps10.pickerHint(sourceBitrate: 5_000_000) == nil)
        #expect(StreamingQuality.original.pickerHint(sourceBitrate: 30_000_000) == nil)
    }

    /// tvOS has one setting; a metered reading there (an Apple TV on a phone hotspot) changes nothing.
    @Test func aPlatformWithoutCellularAlwaysTakesTheWifiRung() {
        #expect(StreamingQuality.resolve(wifi: .mbps10, cellular: .mbps2,
                                         reading: reading(metered: true), platformHasCellular: false) == .mbps10)
    }
}
