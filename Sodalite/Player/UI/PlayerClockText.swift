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
/// there is no end to estimate (live, a pre-roll, an unknown duration). Nothing means no view at all,
/// so a stack around it adds no spacing for it; `reservesSpace` keeps an invisible label instead, for
/// a row that must not jump when the estimate comes and goes.
///
/// The minute timeline is what moves a paused title's end time along with the clock; while playing,
/// the per-second `remainingSeconds` re-evaluates it anyway. `Date()` rather than the timeline's
/// date, because between ticks that date is up to a minute old and would show the end too early.
struct PlayerEndTimeText: View {
    let viewModel: PlayerViewModel
    var reservesSpace = false

    var body: some View {
        if viewModel.preferences.showPlayerClock {
            if viewModel.estimatedEnd() != nil {
                TimelineView(.everyMinute) { _ in
                    label(viewModel.estimatedEnd() ?? Date())
                }
            } else if reservesSpace {
                label(Date()).hidden()
            }
        }
    }

    private func label(_ end: Date) -> some View {
        Text("player.endsAt \(PlayerViewModel.clockLabel(for: end))")
            .monospacedDigit()
    }
}
