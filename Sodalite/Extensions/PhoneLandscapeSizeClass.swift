import SwiftUI

/// A Plus / Pro Max iPhone in landscape reports a REGULAR horizontal size class, the iPad's. Every
/// `horizontalSizeClass == .compact` branch in the app, `LayoutMetrics` included, then took the
/// iPad path on a 440 pt tall screen with no top inset and the tab bar at the bottom: action rows
/// ran off the screen, the profile badge sat on the top edge, the Home hero filled the screen and
/// pushed pages kept the tab bar over their buttons.
///
/// Rather than teach each branch about compact height, the phone keeps the phone layout: in
/// landscape it reports compact width, exactly what every smaller iPhone reports there. That path
/// is the one already tuned for the landscape phone. iPad, Mac and tvOS are untouched.
///
/// Applied at each SwiftUI root (`SodaliteApp`, the player overlay host), since a
/// `UIHostingController` starts from its own traits rather than the app's environment.
struct PhoneLandscapeSizeClass: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    func body(content: Content) -> some View {
        content.environment(\.horizontalSizeClass, Self.resolve(hSizeClass, vertical: vSizeClass,
                                                                    isPhone: Self.isPhone))
    }

    static func resolve(_ horizontal: UserInterfaceSizeClass?,
                        vertical: UserInterfaceSizeClass?,
                        isPhone: Bool) -> UserInterfaceSizeClass? {
        isPhone && vertical == .compact ? .compact : horizontal
    }

    @MainActor private static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

extension View {
    func phoneLandscapeKeepsPhoneLayout() -> some View { modifier(PhoneLandscapeSizeClass()) }
}
