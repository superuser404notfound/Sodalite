import AetherEngine
import Foundation

/// Whether the software path's picture belongs in the app's own window on a wired external display
/// (Sodalite#189).
///
/// The native path reaches that display through AVKit's external playback. The software path draws
/// into a layer in the device's window, which the display only mirrors, so it has to be moved there.
/// The backends are the same two the host mounts its engine surface for. Pure and platform neutral,
/// like `ExternalSubtitleWindowDecision`, so the gating is testable without a UIWindow.
enum ExternalSoftwareVideoDecision {
    static func shouldOwnExternalScreen(backend: PlaybackBackend, externalScenePresent: Bool) -> Bool {
        switch backend {
        case .software, .aether: externalScenePresent
        case .native, .audio, .none: false
        }
    }
}
