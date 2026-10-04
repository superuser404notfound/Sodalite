import SwiftUI

/// The session a detail subtree talks to: the item's own server in a combined Home, nil (meaning
/// the active one) everywhere else (Sodalite#85).
private struct ServerSessionKey: EnvironmentKey {
    static let defaultValue: ServerSession? = nil
}

extension EnvironmentValues {
    var serverSession: ServerSession? {
        get { self[ServerSessionKey.self] }
        set { self[ServerSessionKey.self] = newValue }
    }
}

extension ServerSession {
    /// Delete is coupled to the active server's Seerr/Radarr, downloads to the active server's
    /// download manager, so both stay with it.
    var allowsDeleteAndDownload: Bool { isActive }
}
