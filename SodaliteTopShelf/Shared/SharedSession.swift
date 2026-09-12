import Foundation
import os.log
import Security

nonisolated private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "SharedSession")

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
            log.info("SharedSession.read slot=\(slot, privacy: .public) data=nil group=\(resolvedAccessGroup, privacy: .public)")
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.serverURL)
        else {
            log.error("SharedSession.read decode failed slot=\(slot, privacy: .public)")
            return nil
        }
        log.info("SharedSession.read slot=\(slot, privacy: .public) ok=true group=\(resolvedAccessGroup, privacy: .public)")
        return SharedSession(baseURL: url, userID: payload.userID, accessToken: payload.accessToken)
    }
}

/// Mirrors KeychainKeys.sharedSession; duplicated so the extension stays source-independent from the main target.
nonisolated private let sharedSessionSlot = "tvOSSession_default"

nonisolated enum SharedSessionKeys {
    static let service = "de.superuser404.Sodalite.shared"
    static let accessGroup = "$(AppIdentifierPrefix)de.superuser404.Sodalite.shared"
}

nonisolated private func readSharedKeychainData(account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SharedSessionKeys.service,
        kSecAttrAccount as String: account,
        kSecAttrAccessGroup as String: resolvedAccessGroup,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return data
}

/// `$(AppIdentifierPrefix)` only expands in entitlement plists; at runtime recover the team-ID prefix by reading kSecAttrAccessGroup off any visible keychain item. Falls back to the raw entitlement value for a brand-new install with an empty keychain.
nonisolated private let resolvedAccessGroup: String = {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
    ]
    var item: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess,
       let attrs = item as? [String: Any],
       let group = attrs[kSecAttrAccessGroup as String] as? String,
       let dot = group.firstIndex(of: ".") {
        let prefix = String(group[..<group.index(after: dot)])
        return prefix + "de.superuser404.Sodalite.shared"
    }
    return SharedSessionKeys.accessGroup
}()
