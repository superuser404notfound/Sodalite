#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app-activity transitions the shared code listens for, under whichever name the platform's
/// application class publishes them.
///
/// macOS has no background state to report. An app that is not frontmost on a Mac is still
/// running, still drawing and still playing, so `didLeaveForeground` there is the app losing key
/// status, which is the nearest transition that exists and the one a listener wanting "the viewer
/// is looking at something else now" means.
enum AppActivity {
    #if canImport(UIKit)
    static let didBecomeActive = UIApplication.didBecomeActiveNotification
    static let didLeaveForeground = UIApplication.didEnterBackgroundNotification
    #elseif canImport(AppKit)
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
    static let didLeaveForeground = NSApplication.didResignActiveNotification
    #endif
}
