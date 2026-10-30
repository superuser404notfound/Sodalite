import Foundation
import Security

nonisolated private let log = ShelfLog(category: "SharedSession")

/// Reads the active Jellyfin session from the shared keychain access group the main app mirrors into via SharedSessionMirror. Read-only; missing/undecodable slot is treated as no session (shelf renders empty).
nonisolated struct SharedSession: Sendable {
    let baseURL: URL
    let userID: String
    let accessToken: String
    /// The server a secondary session belongs to (Sodalite#218). nil on the active one, whose items
    /// stay unstamped so their cell identifiers and artwork file names are the ones they always were.
    var serverID: String? = nil

    /// JSON the main app writes into each tvOSSession_<id> slot; kept in sync with SharedSessionMirror.Payload.
    private struct Payload: Codable {
        let serverURL: String
        let userID: String
        let accessToken: String
    }

    /// Reads the blob SharedSessionMirror.write deposits. The keychain is already per tvOS user
    /// under the user-management entitlement, so there is one slot, not one per user.
    static func read() -> SharedSession? {
        let slot = sharedSessionSlot
        guard let data = readSharedKeychainData(account: slot) else {
            log.info("SharedSession.read slot=\(slot) data=nil")
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.serverURL)
        else {
            log.error("SharedSession.read decode failed slot=\(slot)")
            return nil
        }
        log.info("SharedSession.read slot=\(slot) ok=true")
        return SharedSession(baseURL: url, userID: payload.userID, accessToken: payload.accessToken)
    }
}

/// The other servers of a combined Home (Sodalite#218), mirrored by the app into a second slot
/// next to the active session's. Tagged with the active profile it was written for, so a profile
/// switch that has rewritten one slot but not yet the other never pairs a session with the wrong
/// profile's servers.
nonisolated struct ShelfParticipants: Codable, Equatable, Sendable {
    nonisolated struct Member: Codable, Equatable, Sendable {
        let serverID: String
        let serverURL: String
        let userID: String
        let accessToken: String
    }

    let activeUserID: String
    let secondaries: [Member]

    /// Under the `tvOSSession_` prefix on purpose: `SharedSessionMirror.clearAll` sweeps by it.
    nonisolated static let slot = "tvOSSession_participants"

    static func read() -> ShelfParticipants? {
        guard let data = readSharedKeychainData(account: slot) else { return nil }
        return try? JSONDecoder().decode(ShelfParticipants.self, from: data)
    }
}

/// Every session the shelf asks, active first. A single server unless the profile combines them.
nonisolated struct ShelfSessions: Sendable {
    let active: SharedSession
    let secondaries: [SharedSession]

    var all: [SharedSession] { [active] + secondaries }

    static func read() -> ShelfSessions? {
        guard let active = SharedSession.read() else { return nil }
        return ShelfSessions(active: active, participants: ShelfParticipants.read())
    }

    init(active: SharedSession, secondaries: [SharedSession] = []) {
        self.active = active
        self.secondaries = secondaries
    }

    init(active: SharedSession, participants: ShelfParticipants?) {
        self.active = active
        guard let participants, participants.activeUserID == active.userID else {
            self.secondaries = []
            return
        }
        self.secondaries = participants.secondaries.compactMap { member in
            guard let url = URL(string: member.serverURL) else { return nil }
            return SharedSession(baseURL: url, userID: member.userID,
                                 accessToken: member.accessToken, serverID: member.serverID)
        }
    }

    /// The session an item came from, which is the one its artwork and playback belong to.
    func session(for item: TopShelfItem) -> SharedSession {
        guard let serverID = item.sourceServerID else { return active }
        return secondaries.first { $0.serverID == serverID } ?? active
    }
}

/// Mirrors KeychainKeys.sharedSession; duplicated so the extension stays source-independent from the main target.
nonisolated private let sharedSessionSlot = "tvOSSession_default"

nonisolated enum SharedSessionKeys {
    static let service = "de.superuser404.Sodalite.shared"
}

/// No access group in the query. The service is unique to this slot, so searching every group
/// the process is entitled to finds the same item without knowing the team prefix.
///
/// The extension used to probe that prefix off "any visible keychain item" into a `static let`.
/// Its entitlement names only the shared group, so a probe that ran while the slot was empty
/// (before the first login, after a logout, or in the gap of a rewrite) found nothing and pinned
/// the unexpanded `$(AppIdentifierPrefix)` literal for the life of the process. Every read after
/// that failed, and the shelf stayed empty until tvOS happened to recycle the extension.
nonisolated private func readSharedKeychainData(account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SharedSessionKeys.service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        if status != errSecItemNotFound {
            log.error("SharedSession keychain read failed status=\(status)")
        }
        return nil
    }
    return data
}
