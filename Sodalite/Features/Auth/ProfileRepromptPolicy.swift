import Foundation

/// Pure launch decision for the who's-watching reprompt after background time (issue #41).
/// Convenience only, not a security lock: the Guardian PIN keeps gating profile activation.
enum ProfileRepromptPolicy {
    /// A trip that only made the scene inactive (the tvOS screensaver, never `didEnterBackground`)
    /// waits at least this long, so Control Center or a Siri press does not count as leaving even
    /// under "immediately".
    static let inactiveOnlyFloor: Duration = .seconds(60)

    /// `isPlaybackRunning` means a session the viewer can still hear or see on its way (background
    /// audio, PiP, AirPlay). A player left open and PAUSED does not block: the router closes it and
    /// prompts, else anyone could resume another profile's title from it.
    static func shouldReprompt(
        elapsed: Duration,
        interval: AuthPreferences.ProfileRepromptInterval,
        launchBehavior: AuthPreferences.LaunchBehavior,
        isAuthenticated: Bool,
        rememberedCount: Int,
        isPlaybackRunning: Bool,
        tvUserChanged: Bool,
        wasBackgrounded: Bool = true
    ) -> Bool {
        guard let threshold = interval.threshold else { return false }
        guard launchBehavior == .showPicker else { return false }
        guard isAuthenticated, rememberedCount > 1 else { return false }
        guard !isPlaybackRunning, !tvUserChanged else { return false }
        return elapsed >= (wasBackgrounded ? threshold : max(threshold, inactiveOnlyFloor))
    }
}
