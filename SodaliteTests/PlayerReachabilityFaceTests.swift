import Foundation
import Testing
@testable import Sodalite

/// Sodalite#126. The player categorised a connection failure into "Connection problem" on its own,
/// which off the home network is the wrong lead Sodalite#122 deleted from Home: the connection is
/// fine, the address is the problem. The app had already measured why, and the player could not see
/// it, because it is presented from a UIKit modal whose SwiftUI environment starts blank.
///
/// The rule pinned here is the narrow one, and the narrowness is the whole safety argument: the
/// verdict NARROWS a connection failure, it never overrides a typed one. Everything the server
/// answered with, and everything the engine classified, already carries a reason, and a reason beats
/// a circumstance.
@Suite("Player error face from the server verdict")
struct PlayerReachabilityFaceTests {
    private let name = "Home Server"

    // MARK: What the verdict may speak for

    @Test("a verdict names the server on a connection failure")
    func namesTheServer() {
        for error in [APIError.serverUnreachable, .networkError(URLError(.timedOut)), .timeout] {
            let trio = PlayerReachabilityFace.trio(for: error, verdict: .offNetwork, serverName: name)
            #expect(trio?.message.contains(name) == true)
        }
    }

    /// Airplane mode says nothing about the server, so the copy must not either. Not even its name:
    /// a sentence naming a server the app cannot see from here invites the reader to go fix it.
    @Test("no network never names a server")
    func noNetworkNamesNothing() {
        let trio = PlayerReachabilityFace.trio(for: APIError.serverUnreachable, verdict: .noNetwork, serverName: name)
        #expect(trio != nil)
        #expect(trio?.message.contains(name) == false)
        #expect(trio?.title.contains(name) == false)
    }

    /// The vague verdict still improves on the old face by naming which server did not answer, while
    /// claiming nothing about why. It is the honest half of the pair.
    @Test("an unexplained failure still names the server")
    func unreachableNamesTheServer() {
        let trio = PlayerReachabilityFace.trio(for: APIError.serverUnreachable, verdict: .unreachable, serverName: name)
        #expect(trio?.message.contains(name) == true)
    }

    // MARK: What it must never touch

    /// The verdict is a circumstance. These carry a reason, and every one of them can be true while
    /// the server is answering perfectly: an item that is gone, a token that expired, a server that
    /// threw. Overriding them would replace a fact with a guess.
    @Test("a typed failure keeps the face it earned")
    func typedFailuresAreUntouched() {
        let typed: [APIError] = [
            .httpError(statusCode: 404, data: nil),
            .httpError(statusCode: 500, data: nil),
            .unauthorized(message: nil),
            .localNetworkDenied,
            .invalidResponse,
            .invalidURL,
        ]
        for error in typed {
            #expect(PlayerReachabilityFace.trio(for: error, verdict: .offNetwork, serverName: name) == nil)
        }
    }

    /// Sodalite#92's screen is the sharpest case of the rule above: the permission failure has its
    /// own sentence and its own place to send the reader, and a verdict is not allowed to bury it.
    @Test("a Local Network denial outranks every verdict")
    func denialOutranksTheVerdict() {
        for verdict in [ServerReachability.noNetwork, .offNetwork, .unreachable] {
            #expect(PlayerReachabilityFace.trio(for: APIError.localNetworkDenied, verdict: verdict, serverName: name) == nil)
        }
    }

    /// An engine failure was classified by the code that watched it fail. Nothing measured about the
    /// server's address is closer to the truth than that.
    @Test("an engine failure is not the verdict's business")
    func engineFailuresAreUntouched() {
        #expect(PlayerReachabilityFace.trio(for: PlayerEngineError.noSource, verdict: .offNetwork, serverName: name) == nil)
    }

    /// No verdict, or a good one, means the app knows nothing extra and the existing mapping stands.
    /// `.reachable` matters on its own: a connection failure against a server that answered the
    /// probe two seconds ago is a real mystery, and inventing a sentence for it would be a lie.
    @Test("silence and good news both leave the face alone")
    func noVerdictChangesNothing() {
        #expect(PlayerReachabilityFace.trio(for: APIError.serverUnreachable, verdict: .unknown, serverName: name) == nil)
        #expect(PlayerReachabilityFace.trio(for: APIError.serverUnreachable, verdict: .reachable, serverName: name) == nil)
    }
}
