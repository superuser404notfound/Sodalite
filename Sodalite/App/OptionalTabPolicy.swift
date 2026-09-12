import Foundation

/// When the tvOS tab bar may be rebuilt, and when it must be left alone.
///
/// **Rebuilding the tab list throws away the Settings tab's navigation stack** (device-verified in
/// Sodalite#62, which is why the tab-visibility screen commits its edits in `onDisappear`). Three
/// sites re-probe the optional Live TV / Music tabs and write the result: the server switch, a
/// login completion, and the outage recovery of Sodalite#122. Each carried its own idea of when to
/// publish, and the login one published unconditionally, twice: it cleared to the base set at once
/// and put the probed set back a round trip later. Finishing "Add another profile" therefore
/// rebuilt the bar under an open Settings screen and stranded the user on the settings root
/// (Sodalite#141).
///
/// Both decisions return nil for "publish nothing", so a probe that confirms what is already on
/// screen costs no rebuild at all.
enum OptionalTabPolicy {

    /// The set to publish BEFORE a login completion's probe returns, or nil to leave the bar alone.
    ///
    /// Only a login that landed on a different server has anything stale to drop: the Live TV tab
    /// on screen then points at a backend that is gone, and tapping it crashes the EPG stack, which
    /// is worth the navigation stack it costs. Adding another profile on the same server has no
    /// stale backend, so it pays that price for nothing.
    static func setToPublishBeforeLoginProbe(
        onScreen: [AppTab],
        probedServerID: String?,
        activeServerID: String?
    ) -> [AppTab]? {
        guard probedServerID != activeServerID else { return nil }
        return onScreen == AppTab.baseTabs ? nil : AppTab.baseTabs
    }

    /// The set to publish once a probe has returned, or nil if it confirms what is on screen.
    ///
    /// One assignment, never two: two insertions rebuild the bar twice and strand the first item on
    /// tvOS's gray icon template.
    static func setToPublishAfterProbe(
        onScreen: [AppTab],
        hasLiveTV: Bool,
        hasMusic: Bool
    ) -> [AppTab]? {
        let probed = AppTab.probedTabs(hasLiveTV: hasLiveTV, hasMusic: hasMusic)
        return probed == onScreen ? nil : probed
    }
}
