import Foundation

/// What the shell looks like for the profile on screen. Profiles carry their own tabs and navigation
/// style, and a switch that changes either rebuilds the shell under whatever screen was open, which
/// tears down a Settings stack mid-navigation (Sodalite#62, #141). Landing on Home gives that switch a
/// defined destination. A switch between two profiles with the same shell rebuilds nothing and stays.
struct ProfileShellLayout: Equatable {
    let profile: ProfileKey?
    let tabs: [AppTab]
    let style: AppearancePreferences.NavigationStyle

    /// Whether a profile switch pops the Settings stack. A gated screen (Parental Controls, Servers,
    /// iCloud, Tabs, Seerr, Support) asks for the PIN only when it is opened, so a stack the previous
    /// profile unlocked stayed open for the next one, and the reprompt handed exactly that over.
    /// Where the new profile's escapes need no PIN, nothing on the stack was locked and it stays, so
    /// adding a profile still returns to the screen it started from (Sodalite#141).
    static func switchResetsSettings(from old: ProfileKey?, to new: ProfileKey?, escapesGated: Bool) -> Bool {
        guard let old, let new, old != new else { return false }
        return escapesGated
    }

    /// Whether a profile switch re-probes the optional Live TV and Music tabs, which are per user.
    /// A server change is left to the server-switch and login probes, which also drop the stale set.
    static func switchReprobesOptionalTabs(from old: ProfileKey?, to new: ProfileKey?) -> Bool {
        guard let old, let new else { return false }
        return old.serverID == new.serverID && old.userID != new.userID
    }

    static func switchLandsOnHome(from old: ProfileShellLayout, to new: ProfileShellLayout) -> Bool {
        guard let before = old.profile, let after = new.profile, before != after else { return false }
        return old.tabs != new.tabs || old.style != new.style
    }

    /// The tab to select once a shell change is published. A switch that changed the shell lands on
    /// Home, and hiding the tab the viewer is standing on has to land somewhere that still exists.
    static func landingTab(current: AppTab, tabs: [AppTab], landsOnHome: Bool) -> AppTab {
        landsOnHome || !tabs.contains(current) ? .home : current
    }

    /// One `shellLayout` change, resolved into whether to land on Home and which layout to keep
    /// comparing later changes against.
    ///
    /// A switch and the shell it produces do not have to move in the same update. The optional Live
    /// TV and Music tabs are published after two awaited probes, so a switch to a profile on another
    /// server (or one where those libraries differ) settles the profile first and changes the tab set
    /// one or more updates later, with the same profile on both sides of that update. Judged against
    /// the immediately previous value alone, exactly the switch this rule exists for reads as no
    /// change at all. So a switch that has not moved the shell yet keeps the layout it left, and the
    /// next change is judged against that instead.
    ///
    /// The caller drops the latch once the viewer navigates: after that, a tab appearing is the
    /// viewer's own doing and not the switch's.
    static func resolveSwitch(previous: ProfileShellLayout,
                              current: ProfileShellLayout,
                              armedOrigin: ProfileShellLayout?) -> (landsOnHome: Bool, origin: ProfileShellLayout?) {
        if previous.profile != current.profile {
            guard previous.profile != nil, current.profile != nil else { return (false, nil) }
            return switchLandsOnHome(from: previous, to: current) ? (true, nil) : (false, previous)
        }
        guard let origin = armedOrigin else { return (false, nil) }
        return switchLandsOnHome(from: origin, to: current) ? (true, nil) : (false, origin)
    }
}
