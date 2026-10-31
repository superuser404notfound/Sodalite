import SwiftUI

/// Which way a page moves when the tvOS shell switches tabs, shared by the top bar (horizontal) and
/// the sidebar (vertical). A page waits on the side of the shown page its tab sits on in the bar or
/// rail, so a kept page and a page built on its first visit leave and arrive the same way.
enum ShellPageSwitch {
    /// The leaving page clears out quickly and the arriving one starts only once it is nearly gone:
    /// on one shared curve both pages stood half visible over each other mid-switch (seen on device).
    static let fadeOut = Animation.easeOut(duration: 0.15)
    static let fadeIn = Animation.easeOut(duration: 0.25).delay(0.1)

    /// Fade and slide of one page, keyed on whether it is the shown one.
    static func animation(isShown: Bool) -> Animation {
        isShown ? fadeIn : fadeOut
    }

    /// 1 when `new` sits after `old`, -1 before, 0 when either is not among `tabs`.
    static func direction(from old: ShellTab, to new: ShellTab, in tabs: [ShellTab]) -> CGFloat {
        guard let from = tabs.firstIndex(of: old), let to = tabs.firstIndex(of: new), from != to else { return 0 }
        return to < from ? -1 : 1
    }

    /// -1 for a page before the shown one, 1 after it, 0 for the shown page itself.
    static func restingSide(of tab: ShellTab, shown: ShellTab?, in tabs: [ShellTab]) -> CGFloat {
        guard let shown, tab != shown else { return 0 }
        return direction(from: shown, to: tab, in: tabs)
    }
}
