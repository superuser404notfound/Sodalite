import SwiftUI

/// Sodalite#251: the device's clock while the player controls are up. The caller sets the font and
/// decides whether it shows (`PlaybackPreferences.showPlayerClock`).
struct PlayerClockText: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(PlayerViewModel.clockLabel(for: context.date))
                .monospacedDigit()
        }
    }
}

/// Sodalite#251: "Ends at 0:36" beside the remaining time. Draws nothing when the switch is off or
/// there is no end to estimate (live, a pre-roll, an unknown duration).
///
/// The minute timeline is what moves a paused title's end time along with the clock; while playing,
/// the per-second `remainingSeconds` re-evaluates it anyway. `Date()` rather than the timeline's
/// date, because between ticks that date is up to a minute old and would show the end too early.
struct PlayerEndTimeText: View {
    let viewModel: PlayerViewModel

    var body: some View {
        if viewModel.preferences.showPlayerClock {
            TimelineView(.everyMinute) { _ in
                if let end = viewModel.estimatedEnd(now: Date()) {
                    Text("player.endsAt \(PlayerViewModel.clockLabel(for: end))")
                        .monospacedDigit()
                }
            }
        }
    }
}
