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

    @Test func aChannelOutsideTheLineupHasNoNeighbour() {
        #expect(lineup(5).contains("x") == false)
        #expect(lineup(5).neighbour(of: "x", offset: 1) == nil)
    }

    @Test func theZapFilterKeepsFavouritesAndKindOnly() {
        let guide = GuideFilter(favoritesOnly: true, category: .sports, kind: .radio)
        #expect(guide.zapLineup == GuideFilter(favoritesOnly: true, category: nil, kind: .radio))
    }
}
