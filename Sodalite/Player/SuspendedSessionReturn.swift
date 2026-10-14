import Foundation

/// Sodalite#184: what a VOD session does when the app comes back from a suspension that tore its
/// pipeline down (a sleeping Apple TV, a television switched off, Home and a long stay elsewhere).
///
/// The player used to come back on the frame it left and reload there, whatever had happened in
/// between. Its next progress tick and its stop report then wrote that old position over whatever the
/// server had learned meanwhile: an episode finished on a second Apple TV went back to unwatched at
/// yesterday's position and reappeared in Continue Watching.
///
/// While the session is suspended it says nothing to the server (`progressReportsHeldForSuspension`),
/// and on the way back it asks the server first. A session the server moved past closes without a
/// stop report. One that was away long enough closes too, so a television switched on the next day
/// does not open on a paused frame nobody remembers, and reports where it stood only if the server
/// still agrees. Everything else reloads in place as before.
enum SuspendedSessionReturn: Equatable {
    case reload
    case close(reportsStop: Bool)

    var logLabel: String {
        switch self {
        case .reload: "reloading in place"
        case .close(let reportsStop): reportsStop ? "closing with a stop report" : "closing without a stop report"
        }
    }

    /// Long enough that a trip to the Home screen keeps the player, short enough that a night does not.
    static let closeAfterSeconds: TimeInterval = 600

    /// Our own reports land a moment after the suspension began (the Top Shelf refresh sends the
    /// position on the way out), and the two clocks are not the same clock.
    static let serverActivitySlack: TimeInterval = 60

    /// The progress timer reports every 10 s, so a server that heard a tick before the pause and not
    /// the pause itself is off by up to that much without anybody else having played anything.
    static let positionToleranceTicks: Int64 = 15 * 10_000_000

    static func decide(awaySeconds: TimeInterval, serverMovedOn: Bool?) -> SuspendedSessionReturn {
        if serverMovedOn == true { return .close(reportsStop: false) }
        guard awaySeconds >= closeAfterSeconds else { return .reload }
        // An unanswered check closes without a report: the position went out on the way in, and a
        // stop report that might be stale is the bug this exists for.
        return .close(reportsStop: serverMovedOn == false)
    }

    /// Whether another client played this item after the session was suspended.
    ///
    /// A start on any client stamps `LastPlayedDate`, so a newer stamp says someone was here. It does
    /// not say they moved anything, hence the second half: a finish clears the position and sets
    /// `Played`, a partial watch leaves a different position. Without a readable stamp nothing is
    /// known, and the session behaves as it did before.
    static func serverMovedOn(server: UserItemData, suspendedAt: Date, positionTicks: Int64) -> Bool {
        guard let lastPlayed = JellyfinDate.parse(server.lastPlayedDate),
              lastPlayed > suspendedAt.addingTimeInterval(serverActivitySlack) else { return false }
        if server.played == true { return true }
        return abs((server.playbackPositionTicks ?? 0) - positionTicks) > positionToleranceTicks
    }
}
