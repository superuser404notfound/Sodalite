import Foundation

/// How often the app re-asks a server that is not answering, and how soon a failed request may
/// prompt it to ask at all (Sodalite#126).
///
/// Separated from the container so the schedule is pinned by tests instead of by a stopwatch. The
/// numbers carry an argument rather than a taste: the probe behind them is an unauthenticated GET
/// capped at two seconds, so the cost is bounded whatever the interval, and the interval only
/// decides how long a reader looks at a sentence that has stopped being true.
enum ReachabilityRecheck {
    /// Backing off rather than a flat interval, because the two ends want different things. A server
    /// that was just restarted comes back within seconds and the first checks should catch it; a
    /// server that is off for the evening should not be asked every five seconds all night.
    private static let schedule: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)]

    /// The steady state, once the early checks have not found it.
    static let ceiling: Duration = .seconds(30)

    static func delay(forAttempt attempt: Int) -> Duration {
        guard attempt >= 0 else { return schedule[0] }
        return attempt < schedule.count ? schedule[attempt] : ceiling
    }

    /// The shortest gap between two re-measures prompted by a failed request.
    ///
    /// A failing session produces failures by the dozen and they are all one piece of news. It also
    /// guards the odd case the watch does not cover: a server that answers the probe endpoint while
    /// its API keeps failing would otherwise turn every request into another probe.
    static let cooldown: Duration = .seconds(10)
}
