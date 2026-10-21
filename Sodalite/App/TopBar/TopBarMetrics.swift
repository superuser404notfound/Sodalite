import CoreGraphics

/// The tvOS top bar Sodalite draws itself. Its place on screen is the system bar's, measured in the
/// tvOS 26 simulator with XCUITest (2026-10-21): the bar's frame at y=46, 68pt tall, and a tab's
/// root content starting at y=157. Keeping those numbers is what lets every page keep the layout it
/// was built against.
///
/// The system bar did not fit: its glass pill is capped at 1252pt, and six German tabs need about
/// 1310, so the last one was cut off (project_tabbar_truncation_accepted). Here only the selected
/// tab carries its title, the others show their icon, which is what makes room for seven.
enum TopBarMetrics {
    static let barTop: CGFloat = 46
    static let barHeight: CGFloat = 68
    /// Where a tab's root content began under the system bar.
    static let contentTop: CGFloat = 157
    /// tvOS's own title-safe margin at the top, which the content already sits below.
    static let systemSafeTop: CGFloat = 60
    /// What the bar adds to the safe area of a tab's root page.
    static var contentInset: CGFloat { contentTop - systemSafeTop }

    /// How far the bar has to travel to be fully off screen, for the scroll that carries it away.
    static var travel: CGFloat { barTop + barHeight }

    static let panelPadding: CGFloat = 6
    static let itemSpacing: CGFloat = 4
    static let itemHorizontalPadding: CGFloat = 22
    static var itemHeight: CGFloat { barHeight - panelPadding * 2 }
    /// Same diameter the sidebar gives its profile avatar, so the two shells show one picture.
    static let avatarDiameter: CGFloat = 36
    static let labelSpacing: CGFloat = 12
}
