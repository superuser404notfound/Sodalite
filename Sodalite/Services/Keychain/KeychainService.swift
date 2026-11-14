import Foundation
import Security

/// nonisolated throughout: every method is a SecItem call, which is thread-safe and has no business
/// on the main actor. It is read from one place that cannot be on it at all, the certificate-pin
/// store behind `ServerTrustDelegate.shared`, which the first URLSession in the process needs.
nonisolated protocol KeychainServiceProtocol: Sendable {
    func save(_ data: Data, for key: String) throws
    func save(_ string: String, for key: String) throws
    func loadData(for key: String) throws -> Data?
    func loadString(for key: String) throws -> String?
    func delete(for key: String) throws
    func deleteAll() throws
}

nonisolated final class KeychainService: KeychainServiceProtocol {
    private let service: String

    /// What each item held when this process last read or wrote it, `.some(nil)` for "not there".
    /// Every SecItem call is an IPC round trip to securityd, and `DependencyContainer.activeUserID`
    /// alone makes three of them, from view bodies on the main thread. Nothing outside this class
    /// writes these items (the Top Shelf mirror has its own), so every change passes through here.
    /// Shared by all instances, because the container and the certificate-pin store each build one
    /// and the container's `deleteAll` also clears the pins. A failed read is never stored.
    private static let cacheLock = NSLock()
    /// Keyed by `service` + NUL + `account`. A String key, not a small Hashable struct: the first use
    /// of a dictionary over a type of our own makes the runtime look up that conformance, and on the
    /// launch path that lookup cost about 500 ms in a tvOS simulator trace.
    nonisolated(unsafe) private static var cache: [String: Data?] = [:]

    private func cacheKey(_ account: String) -> String {
        service + "\u{0}" + account
    }

    private func cached(_ key: String) -> Data?? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        return Self.cache[cacheKey(key)]
    }

    private func remember(_ data: Data?, for key: String) {
        Self.cacheLock.lock()
        Self.cache[cacheKey(key)] = .some(data)
        Self.cacheLock.unlock()
    }

    private func forget(_ key: String) {
        Self.cacheLock.lock()
        Self.cache[cacheKey(key)] = nil
        Self.cacheLock.unlock()
    }

    /// nonisolated so the certificate-pin store can be built before the main actor exists for it:
    /// `ServerTrustDelegate.shared` is read by the first `URLSession` this app makes, which is a
    /// default argument of `DependencyContainer.init`. Nothing here touches shared state.
    nonisolated init(service: String = KeychainKeys.service) {
        self.service = service
    }

    // Per-user isolation is the SecItem default under runs-as-current-user; omit kSecUseUserIndependentKeychain (setting it false is rejected -50 on SecItemDelete). Access groups (kSecAttrAccessGroup) govern cross-PROCESS not cross-USER sharing; omitted so the OS picks the first entitled group.

    func save(_ data: Data, for key: String) throws {
        // Upsert (update-then-add), NOT delete-then-add: delete+add lost the old token if the add failed and could collide on errSecDuplicateItem under interleaved saves.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        // Unknown until the write has an outcome, so a failure cannot leave the old value cached.
        forget(key)
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            remember(data, for: key)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        remember(data, for: key)
    }

    func save(_ string: String, for key: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try save(data, for: key)
    }

    func loadData(for key: String) throws -> Data? {
        if let known = cached(key) { return known }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            let data = result as? Data
            remember(data, for: key)
            return data
        case errSecItemNotFound:
            remember(nil, for: key)
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    func loadString(for key: String) throws -> String? {
        guard let data = try loadData(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        forget(key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
        remember(nil, for: key)
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        Self.cacheLock.lock()
        let prefix = service + "\u{0}"
        Self.cache = Self.cache.filter { !$0.key.hasPrefix(prefix) }
        Self.cacheLock.unlock()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    /// The OSStatus stays in the sentence: it is the only part a support thread can act on, and it is a
    /// number, so it survives translation. Which of the three operations failed does not reach the
    /// viewer, because "saving" and "loading" a keychain item are the same event from where they sit.
    var errorDescription: String? {
        switch self {
        case .saveFailed(let status), .loadFailed(let status), .deleteFailed(let status):
            String(
                format: String(
                    localized: "error.keychain.accessFailed",
                    defaultValue: "Could not access the keychain (%lld)."
                ),
                Int64(status)
            )
        case .encodingFailed:
            String(
                localized: "error.keychain.encodingFailed",
                defaultValue: "Could not prepare this data for the keychain."
            )
        }
    }
}
