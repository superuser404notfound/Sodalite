import AetherEngine
import SwiftUI
import UIKit

/// Owns the app's window on a wired external display while the software path plays (Sodalite#189).
///
/// The native path reaches an external screen through AVKit's external playback, which the software
/// path has no part in: it draws into a sample-buffer layer in this device's own window, so without
/// this the display only mirrors the whole device screen (picture, controls and all). Binding the
/// engine to a surface in a window on the display's scene moves the layer there; the device keeps
/// the transport over the remote view, as it does for the native path.
@MainActor
final class ExternalSoftwareVideoWindowController {
    private(set) var isShowingVideo = false

    private var window: UIWindow?
    private var surface: AetherPlayerView?
    private var sceneStateObservers: [NSObjectProtocol] = []

    /// `connecting` is the scene a connect notification names, which may not be listed among the
    /// application's connected scenes yet while the notification is delivered.
    func update(engine: AetherEngine, viewModel: PlayerViewModel, connecting: UIWindowScene? = nil) {
        let scene = connecting ?? ExternalSubtitleWindowController.currentExternalScene()
        guard ExternalSoftwareVideoDecision.shouldOwnExternalScreen(
                backend: engine.playbackBackend, externalScenePresent: scene != nil),
              let scene else {
            tearDown(engine: engine)
            return
        }
        if let window, window.windowScene === scene, let surface {
            // The host remounted its own surface (a reload across a backend change), which made that
            // one the engine's most recent binding; bind ours again so the picture stays out there.
            engine.bind(view: surface)
            return
        }
        tearDown(engine: engine)
        showWindow(on: scene, engine: engine, viewModel: viewModel)
    }

    func tearDown(engine: AetherEngine) {
        guard let window else { return }
        if let surface { engine.unbind(view: surface) }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        surface = nil
        isShowingVideo = false
        sceneStateObservers.forEach(NotificationCenter.default.removeObserver)
        sceneStateObservers.removeAll()
        LogTap.shared.note("[ExternalVideo] window torn down, software picture back on the device")
    }

    private func showWindow(on scene: UIWindowScene, engine: AetherEngine, viewModel: PlayerViewModel) {
        let surface = AetherPlayerView()
        let root = ExternalSoftwareVideoRoot(surface: surface, viewModel: viewModel)
        let newWindow = UIWindow(windowScene: scene)
        newWindow.backgroundColor = .black
        newWindow.isUserInteractionEnabled = false
        newWindow.rootViewController = root
        newWindow.isHidden = false
        window = newWindow
        self.surface = surface
        engine.bind(view: surface)
        isShowingVideo = true
        observeSceneState(scene)
        LogTap.shared.note(
            "[ExternalVideo] software picture moved to external scene "
            + "\(scene.effectiveGeometry.coordinateSpace.bounds.size) state=\(Self.describe(scene.activationState))")
    }

    /// Whether the display's scene stays in the foreground while the device locks decides if the
    /// software picture can survive a lock at all; this is the line a report needs to answer that.
    private func observeSceneState(_ scene: UIWindowScene) {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIScene.willDeactivateNotification, "willDeactivate"),
            (UIScene.didEnterBackgroundNotification, "didEnterBackground"),
            (UIScene.willEnterForegroundNotification, "willEnterForeground"),
            (UIScene.didActivateNotification, "didActivate"),
        ]
        for (name, event) in names {
            let token = center.addObserver(forName: name, object: scene, queue: .main) { [weak scene] _ in
                MainActor.assumeIsolated {
                    let state = scene.map { Self.describe($0.activationState) } ?? "gone"
                    let app = Self.describe(UIApplication.shared.applicationState)
                    LogTap.shared.note("[ExternalVideo] external scene \(event) state=\(state) app=\(app)")
                }
            }
            sceneStateObservers.append(token)
        }
    }

    private static func describe(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive: "foregroundActive"
        case .foregroundInactive: "foregroundInactive"
        case .background: "background"
        case .unattached: "unattached"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

/// Root of the external-display window on the software path: the engine's surface under the same
/// subtitle overlay the native takeover draws (Sodalite#98). Non-interactive, so it carries no controls.
@MainActor
private final class ExternalSoftwareVideoRoot: UIViewController {
    private let surface: AetherPlayerView
    private let subtitles: UIHostingController<ExternalSubtitleView>

    init(surface: AetherPlayerView, viewModel: PlayerViewModel) {
        self.surface = surface
        subtitles = UIHostingController(rootView: ExternalSubtitleView(viewModel: viewModel))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surface)
        addChild(subtitles)
        subtitles.view.backgroundColor = .clear
        subtitles.view.frame = view.bounds
        subtitles.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(subtitles.view)
        subtitles.didMove(toParent: self)
    }
}
