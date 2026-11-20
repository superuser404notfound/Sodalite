import SwiftUI

/// Which server and user a detail page talks to (audit DET-R202). Every detail page used to carry
/// its own copy of these two lines.
extension ServerSession {
    /// The item's own server in a combined Home, the active one otherwise (Sodalite#85).
    @MainActor
    static func forDetail(_ override: ServerSession?, _ dependencies: DependencyContainer) -> ServerSession {
        override ?? dependencies.sessionRegistry.active
    }

    /// The active session follows the signed-in profile, a secondary server keeps its own user.
    @MainActor
    func detailUserID(appState: AppState) -> String? {
        isActive ? appState.activeUser?.id : userID
    }
}
