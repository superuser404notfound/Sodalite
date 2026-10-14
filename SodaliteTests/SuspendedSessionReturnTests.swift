import Foundation
import Testing
@testable import Sodalite

/// Sodalite#184: a session woken from a suspension must not write its old position over what another
/// client told the server in the meantime.
@Suite("Suspended session return")
struct SuspendedSessionReturnTests {

    private let suspendedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute: Int64 = 60 * 10_000_000

    private func server(played: Bool = false, positionTicks: Int64?, lastPlayed: Date?) -> UserItemData {
        UserItemData(playbackPositionTicks: positionTicks, playCount: 1, isFavorite: false, played: played,
                     unplayedItemCount: nil, playedPercentage: nil,
                     lastPlayedDate: lastPlayed.map(JellyfinDate.format))
    }

    @Test("a short trip with an unchanged server reloads in place")
    func shortTripReloads() {
        #expect(SuspendedSessionReturn.decide(awaySeconds: 30, serverMovedOn: false) == .reload)
        #expect(SuspendedSessionReturn.decide(awaySeconds: 30, serverMovedOn: nil) == .reload)
    }

    @Test("a server that moved on closes without a stop report, however short the trip")
    func movedServerClosesSilently() {
        #expect(SuspendedSessionReturn.decide(awaySeconds: 30, serverMovedOn: true) == .close(reportsStop: false))
        #expect(SuspendedSessionReturn.decide(awaySeconds: 86_400, serverMovedOn: true) == .close(reportsStop: false))
    }

    @Test("a long trip closes, and reports only what the server confirmed")
    func longTripCloses() {
        let limit = SuspendedSessionReturn.closeAfterSeconds
        #expect(SuspendedSessionReturn.decide(awaySeconds: limit - 1, serverMovedOn: false) == .reload)
        #expect(SuspendedSessionReturn.decide(awaySeconds: limit, serverMovedOn: false) == .close(reportsStop: true))
        #expect(SuspendedSessionReturn.decide(awaySeconds: limit, serverMovedOn: nil) == .close(reportsStop: false))
    }

    @Test("the reported case: finished on another Apple TV the next day")
    func finishedElsewhere() {
        let data = server(played: true, positionTicks: 0, lastPlayed: suspendedAt.addingTimeInterval(3_600))
        #expect(SuspendedSessionReturn.serverMovedOn(server: data, suspendedAt: suspendedAt, positionTicks: 20 * minute))
    }

    @Test("watched further elsewhere moves the position")
    func watchedFurtherElsewhere() {
        let data = server(positionTicks: 35 * minute, lastPlayed: suspendedAt.addingTimeInterval(600))
        #expect(SuspendedSessionReturn.serverMovedOn(server: data, suspendedAt: suspendedAt, positionTicks: 20 * minute))
    }

    @Test("our own report on the way out is not somebody else")
    func ownReportInsideSlack() {
        let data = server(positionTicks: 0, lastPlayed: suspendedAt.addingTimeInterval(5))
        #expect(!SuspendedSessionReturn.serverMovedOn(server: data, suspendedAt: suspendedAt, positionTicks: 20 * minute))
    }

    @Test("a stamp from before the suspension says nothing")
    func olderStamp() {
        let data = server(played: true, positionTicks: 0, lastPlayed: suspendedAt.addingTimeInterval(-3_600))
        #expect(!SuspendedSessionReturn.serverMovedOn(server: data, suspendedAt: suspendedAt, positionTicks: 20 * minute))
    }

    @Test("a newer stamp at our own position is not a move")
    func newerStampSamePosition() {
        let data = server(positionTicks: 20 * minute + 10 * 10_000_000, lastPlayed: suspendedAt.addingTimeInterval(600))
        #expect(!SuspendedSessionReturn.serverMovedOn(server: data, suspendedAt: suspendedAt, positionTicks: 20 * minute))
    }

    @Test("no readable stamp keeps the old behaviour")
    func missingStamp() {
        let data = server(played: true, positionTicks: 0, lastPlayed: nil)
        #expect(!SuspendedSessionReturn.serverMovedOn(server: data, suspendedAt: suspendedAt, positionTicks: 20 * minute))
    }
}
