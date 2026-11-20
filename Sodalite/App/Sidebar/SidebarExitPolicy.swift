/// Sodalite#140. The Menu key, which a `TabView` answers by itself and a hand-built shell does not.
/// The chain is tvOS convention: leave the content, then land on the landing tab, and only from
/// there leave the app. Skipping a step makes the first Menu press quit Sodalite mid-browse.
enum SidebarExitPolicy {
    enum Outcome: Equatable {
        case focusRail
        case selectHome
        case leaveApp
    }

    static func next(focusIsInRail: Bool, selectedTab: ShellTab) -> Outcome {
        guard focusIsInRail else { return .focusRail }
        return selectedTab == .home ? .leaveApp : .selectHome
    }
}
