import Testing
@testable import Sodalite

struct LiveChannelLineupTests {
    private func lineup(_ count: Int) -> LiveChannelLineup {
        LiveChannelLineup(channels: (0..<count).map {
            JellyfinChannel(id: "c\($0)", name: "C\($0)", channelNumber: "\($0 + 1)",
                            imageTags: nil, currentProgram: nil, userData: nil)
        })
    }

    @Test func upAndDownStepOneChannel() {
        #expect(lineup(5).neighbour(of: "c2", offset: 1)?.id == "c3")
        #expect(lineup(5).neighbour(of: "c2", offset: -1)?.id == "c1")
    }

    @Test func theEndsWrapAround() {
        #expect(lineup(5).neighbour(of: "c4", offset: 1)?.id == "c0")
        #expect(lineup(5).neighbour(of: "c0", offset: -1)?.id == "c4")
    }

    @Test func anAccumulatedOffsetWrapsAsOften() {
        #expect(lineup(200).neighbour(of: "c10", offset: 3)?.id == "c13")
        #expect(lineup(200).neighbour(of: "c10", offset: -250)?.id == "c160")
    }

    @Test func aLineupOfOneOrNoneHasNoNeighbour() {
        #expect(lineup(1).neighbour(of: "c0", offset: 1) == nil)
        #expect(lineup(0).neighbour(of: "c0", offset: 1) == nil)
    }

    @Test func skippedChannelsAreSteppedOver() {
        #expect(lineup(3).neighbour(of: "c0", offset: 1, skipping: ["c1"])?.id == "c2")
        #expect(lineup(3).neighbour(of: "c0", offset: -1, skipping: ["c2"])?.id == "c1")
        #expect(lineup(5).neighbour(of: "c0", offset: 2, skipping: ["c1", "c3"])?.id == "c4")
    }

    @Test func aPickedChannelIsReachedTheShorterWayRound() throws {
        let channels = lineup(10)
        #expect(channels.offset(from: "c2", to: "c5") == 3)
        #expect(channels.offset(from: "c2", to: "c0") == -2)
        #expect(channels.offset(from: "c1", to: "c9") == -2)
        #expect(channels.offset(from: "c9", to: "c1") == 2)
        let offset = try #require(channels.offset(from: "c8", to: "c3"))
        #expect(channels.neighbour(of: "c8", offset: offset)?.id == "c3")
    }

    @Test func aPickedChannelCountsOnlyTheChannelsNotSkipped() throws {
        let channels = lineup(6)
        let offset = try #require(channels.offset(from: "c0", to: "c4", skipping: ["c1", "c2"]))
        #expect(offset == 2)
        #expect(channels.neighbour(of: "c0", offset: offset, skipping: ["c1", "c2"])?.id == "c4")
    }

    @Test func pickingTheSameMissingOrSkippedChannelGoesNowhere() {
        #expect(lineup(5).offset(from: "c1", to: "c1") == nil)
        #expect(lineup(5).offset(from: "c1", to: "x") == nil)
        #expect(lineup(5).offset(from: "c1", to: "c3", skipping: ["c3"]) == nil)
    }

    @Test func everyOtherChannelSkippedMeansNoZap() {
        #expect(lineup(3).neighbour(of: "c0", offset: 1, skipping: ["c1", "c2"]) == nil)
    }

    @Test func aChannelOutsideTheLineupHasNoNeighbour() {
        #expect(lineup(5).contains("x") == false)
        #expect(lineup(5).neighbour(of: "x", offset: 1) == nil)
    }

    @Test func theZapFilterKeepsFavouritesAndKindOnly() {
        let guide = GuideFilter(favoritesOnly: true, category: .sports, kind: .radio)
        #expect(guide.zapLineup == GuideFilter(favoritesOnly: true, category: nil, kind: .radio))
    }
}
