import Foundation
import os.log
import Security

/// Mirrors active Jellyfin credentials into the shared keychain access group the TopShelf extension reads. One JSON `Payload` in a single slot, re-mirrored on every login/profile-switch/logout; the keychain itself is per tvOS user under the user-management entitlement. Own service bucket (`…Sodalite.shared`) to keep it separate from the app's primary entries.
enum SharedSessionMirror {
    static let service = "de.superuser404.Sodalite.shared"

    /// JSON shape per slot; keep in sync with the decoder in `SodaliteTopShelf/SharedSession.swift`.
    struct Payload: Codable {
        let serverURL: String
        let userID: String
        let accessToken: String
    }

    static func write(serverURL: URL, userID: String, accessToken: String) {
        // Only tvOS has a Top Shelf to read this. Everywhere else the write would mint a second copy
        // of the access token with no consumer, so take the chance to remove one an earlier build of
        // this app left behind instead.
        #if !os(tvOS)
        clear()
        return
        #else
        let slot = KeychainKeys.sharedSession
        let payload = Payload(
            serverURL: serverURL.absoluteString,
            userID: userID,
            accessToken: accessToken
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            log.error("SharedSessionMirror.write encode failed slot=\(slot, privacy: .public)")
            return
        }
        save(data, account: slot)
        TopShelfRefresher.invalidate()
        #endif
    }

    static func clear() {
        let slot = KeychainKeys.sharedSession
        delete(account: slot)
        // The extension's own identity check already refuses a foreign cache; this is the
        // tidy-up so a logged-out device carries no library titles in its container.
        TopShelfCachePolicy.delete()
        // Without this the shelf keeps serving the previous profile's cells until tvOS
        // asks again on its own schedule.
        TopShelfRefresher.invalidate()
    }

    /// Wipes every shared-session slot (full logout). Enumerates by `tvOSSession_` account-prefix since SecItem has no prefix match.
    static func clearAll() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("tvOSSession_")
            else { continue }
            delete(account: account)
        }
        TopShelfCachePolicy.delete()
        TopShelfRefresher.invalidate()
    }

    /// Updates in place and adds only when there is nothing to update. Delete-then-add left a
    /// window with no slot at all, and every launch rewrites it during session restore, which is
    /// exactly when tvOS tends to ask the extension for a fresh shelf.
    private static func save(_ data: Data, account: String) {
        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = resolvedAccessGroup {
            match[kSecAttrAccessGroup as String] = group
        }
        // ThisDeviceOnly, matching KeychainService: this is the same access token, and the reader
        // is an extension on this very device. Without the suffix the item is backup-eligible and
        // the token restores onto a different device, which is more reach than the Top Shelf needs.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("SharedSessionMirror.save failed: status=\(status, privacy: .public) account=\(account, privacy: .public)")
        }
    }

    private static func delete(account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Materializes `<TeamID>.de.superuser404.Sodalite.shared` at runtime ($(AppIdentifierPrefix) expands only at codesign). Cribs the team prefix off any visible keychain item, and on an empty keychain off a throwaway item added to the default group. Without that second step a fresh install wrote the mirror with no access group, which lands it in the FIRST entitled group (the app's private one) where the extension cannot see it. Caches only a successful probe.
    private static var cachedAccessGroup: String?
    private static var resolvedAccessGroup: String? {
        if let cachedAccessGroup { return cachedAccessGroup }
        guard let prefix = teamPrefix() else {
            log.notice("SharedSessionMirror could not probe team prefix; falling back to default group")
            return nil
        }
        let resolved = prefix + "de.superuser404.Sodalite.shared"
        cachedAccessGroup = resolved
        return resolved
    }

    private static func teamPrefix() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: AnyObject?
        if SecItemCopyMatching(probe as CFDictionary, &item) == errSecSuccess,
           let prefix = prefix(of: item) {
            return prefix
        }

        let marker: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".probe",
            kSecAttrAccount as String: "teamPrefix",
        ]
        defer { SecItemDelete(marker as CFDictionary) }
        var added: AnyObject?
        var add = marker
        add[kSecReturnAttributes as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, &added) == errSecSuccess else { return nil }
        return prefix(of: added)
    }

    private static func prefix(of item: AnyObject?) -> String? {
        guard let attrs = item as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else { return nil }
        return String(group[..<group.index(after: dot)])
    }

    private static let log = Logger(subsystem: "de.superuser404.Sodalite", category: "TopShelfMirror")
}
