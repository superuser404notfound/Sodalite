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
        guard let threshold = interval.threshold,
              canReprompt(interval: interval, launchBehavior: launchBehavior,
                          isAuthenticated: isAuthenticated, rememberedCount: rememberedCount)
        else { return false }
        guard !isPlaybackRunning, !tvUserChanged else { return false }
        return elapsed >= (wasBackgrounded ? threshold : max(threshold, inactiveOnlyFloor))
    }

    /// The time-independent half of `shouldReprompt`: whether any return to the app could bring the
    /// picker up. Decides on the way out, before anyone knows how long the trip lasts, whether the
    /// privacy shield goes over the app (Sodalite#184).
    static func canReprompt(
        interval: AuthPreferences.ProfileRepromptInterval,
        launchBehavior: AuthPreferences.LaunchBehavior,
        isAuthenticated: Bool,
        rememberedCount: Int
    ) -> Bool {
        interval.threshold != nil && launchBehavior == .showPicker && isAuthenticated && rememberedCount > 1
    }
}
