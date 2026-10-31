import CoreGraphics

/// Which way a page moves when the tvOS shell switches tabs, shared by the top bar (horizontal) and
/// the sidebar (vertical). A page waits on the side of the shown page its tab sits on in the bar or
/// rail, so a kept page and a page built on its first visit leave and arrive the same way.
enum ShellPageSwitch {
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
