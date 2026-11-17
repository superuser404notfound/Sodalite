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

    /// What a due reprompt does about the surfaces that are open when it comes due (SHELL-202).
    enum CoverPlan: Equatable {
        /// What's New or an earlier reprompt owns the host. The caller keeps the trip for What's New
        /// and re-arms once it closes, never spends it (R-LIFECYCLE-8).
        case skip
        case armNow
        /// Close these first, wait for the settle, then arm. Never skip: a detail cover or the music
        /// player left open would hand the next viewer this profile's library behind the picker.
        /// `closeDetailCovers` covers every presented detail cover (the router's deep link and the tab
        /// pages' own), `closeProfileCover` a chooser or server-switch cover that can be swiped away.
        case closeThenArm(closePlayer: Bool, closeRouterCovers: Bool, closeProfileCover: Bool)
    }

    static func coverPlan(
        playerUp: Bool,
        panelUp: Bool,
        detailCoverUp: Bool,
        musicPlayerUp: Bool,
        whatsNewUp: Bool,
        repromptCoverUp: Bool,
        otherProfileCoverUp: Bool,
        awaitsDismissal: Bool
    ) -> CoverPlan {
        guard !whatsNewUp, !repromptCoverUp, !awaitsDismissal else { return .skip }
        let routerCovers = detailCoverUp || musicPlayerUp
        guard playerUp || panelUp || routerCovers || otherProfileCoverUp else { return .armNow }
        return .closeThenArm(closePlayer: playerUp, closeRouterCovers: routerCovers,
                             closeProfileCover: otherProfileCoverUp)
    }
}
