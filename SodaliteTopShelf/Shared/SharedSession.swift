import Foundation
import Security

nonisolated private let log = ShelfLog(category: "SharedSession")

/// Reads the active Jellyfin session from the shared keychain access group the main app mirrors into via SharedSessionMirror. Read-only; missing/undecodable slot is treated as no session (shelf renders empty).
nonisolated struct SharedSession: Sendable {
    let baseURL: URL
    let userID: String
    let accessToken: String

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
