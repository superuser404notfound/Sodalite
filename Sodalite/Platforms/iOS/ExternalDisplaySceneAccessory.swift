import UIKit

/// Asks iOS 27 for a scene on a wired external display while the software path plays (Sodalite#189).
///
/// An app built with the iOS 27 SDK is only handed a `windowExternalDisplayNonInteractive` scene when a
/// view controller registers one as a scene accessory; the Info.plist role covers iOS 26 and earlier
/// only. AVKit registers its own for the native path, which is why an MP4 reached the display and an
/// MPEG-2 title on the software path kept mirroring the iPad (iPad mini 6, iPadOS 27, Build 7).
/// Registered only while the software surface is mounted, so the native path's display stays AVKit's.
@MainActor
final class ExternalDisplaySceneAccessory {
    private var registration: AnyObject?

    func setActive(_ active: Bool, on host: UIViewController) {
        guard #available(iOS 27.0, *) else { return }
        if active {
            guard registration == nil else { return }
            let configuration = UISceneConfiguration(
                name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
            let registration = host.registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
            self.registration = registration
            LogTap.shared.note("[ExternalVideo] scene accessory registered available=\(registration.isAvailable)")
        } else {
            guard let registration = registration as? UISceneAccessoryRegistration else { return }
            host.unregisterSceneAccessory(registration)
            self.registration = nil
            LogTap.shared.note("[ExternalVideo] scene accessory unregistered")
        }
    }
}

/// The accessory's configuration has to name a delegate class. The window on the scene is owned by
/// `ExternalSoftwareVideoWindowController`, which finds the scene through the connect notification.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
