import Foundation

/// Whether the app's measured server verdict may speak for a playback failure, and what it says
/// (Sodalite#126).
///
/// The player categorised an `APIError.serverUnreachable` into "Connection problem" on its own,
/// which off the home network is the same wrong lead Sodalite#122 deleted from Home: the connection
/// is fine, the address is the problem, and the sentence sends the reader to restart a router they
/// are nowhere near. The app had already measured why, once, for the whole session. The player could
/// not see it because it is presented from a UIKit modal whose SwiftUI environment starts blank, so
/// the verdict is handed in rather than read out of the environment.
///
/// The rule is narrow, and the narrowness is the safety argument. The verdict NARROWS a connection
/// failure; it never overrides a typed one. An item that is gone, a token that expired, a server
/// that threw, a denied Local Network permission and every engine classification keep the face they
/// earned, because each of those can be true while the server answers perfectly. A reason beats a
/// circumstance. Same shape as `ServerReachability.blockingState`, and the same reason behind it:
/// say the more specific sentence only where the more specific thing is actually known.
enum PlayerReachabilityFace {
    struct Trio: Equatable {
        let icon: String
        let title: String
        let message: String
    }

    /// The failures a verdict about the server address can explain. Everything else already carries
    /// a reason of its own.
    private static func isExplainable(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        switch api {
        case .serverUnreachable, .networkError, .timeout:
            return true
        case .invalidURL, .invalidResponse, .httpError, .decodingError, .unauthorized, .localNetworkDenied:
            return false
        }
    }

    static func trio(for error: Error, verdict: ServerReachability, serverName: String) -> Trio? {
        guard isExplainable(error) else { return nil }
        switch verdict {
        case .noNetwork:
            // Nothing about the server is knowable from here, so nothing here is about the server.
            // Not even its name: naming one invites the reader to go and fix it.
            return Trio(
                icon: "wifi.slash",
                title: String(localized: "player.error.noNetwork.title", defaultValue: "No network connection"),
                message: String(
                    localized: "player.error.noNetwork.body",
                    defaultValue: "This device is not connected to a network right now."
                )
            )
        case .offNetwork:
            return Trio(
                icon: "network.slash",
                title: String(localized: "player.error.offNetwork.title", defaultValue: "Server not on this network"),
                message: String(
                    format: String(localized: "server.offNetwork.title %@"),
                    serverName
                )
            )
        case .unreachable:
            // The vague half. It keeps the old headline, because the app genuinely does not know
            // why, and improves only on the body, which now names which server did not answer.
            return Trio(
                icon: "network.slash",
                title: String(localized: "player.error.connection.title", defaultValue: "Connection problem"),
                message: String(
                    format: String(localized: "server.unreachable.title %@"),
                    serverName
                )
            )
        case .reachable, .unknown:
            // A connection failure against a server that answered the probe seconds ago is a real
            // mystery, and inventing a sentence for it would be a lie.
            return nil
        }
    }
}
