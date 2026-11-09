import Foundation

nonisolated enum KeychainKeys {
    static let service = "de.superuser404.Sodalite"

    static func accessToken(serverID: String) -> String {
        "accessToken_\(serverID)"
    }

    static func userID(serverID: String) -> String {
        "userID_\(serverID)"
    }

    /// A password belongs to one profile, so the key carries the profile. Scoped per server too,
    /// because the same account name can exist on several servers with different passwords.
    static func jellyfinPassword(serverID: String, userID: String) -> String {
        "jellyfinPassword_\(serverID)_\(userID)"
    }

    /// Pre-per-user layout: one password per server, with the owner in a second entry. Both are
    /// migrated into `jellyfinPassword(serverID:userID:)` on launch and then removed.
    static func legacyJellyfinPassword(serverID: String) -> String {
        "jellyfinPassword_\(serverID)"
    }

    /// The user id the legacy per-server password belonged to.
    static func legacyJellyfinPasswordUserID(serverID: String) -> String {
        "jellyfinPasswordUserID_\(serverID)"
    }

    /// JSON `[RememberedUser]` for one server, single blob so profile add/remove is an atomic write.
    static func rememberedUsers(serverID: String) -> String {
        "rememberedUsers_\(serverID)"
    }

    /// JSON `[String]` of profile ids removed here on purpose (Sodalite#45). The remembered list
    /// unions across devices, so a removal has to be published as one, else the device that has not
    /// heard yet hands the profile straight back. Cleared per id by signing in as that profile again.
    static func forgottenUsers(serverID: String) -> String {
        "forgottenUsers_\(serverID)"
    }

    static let seerrServer = "seerrServer"

    /// JSON `[JellyfinServer]`. Order is significant: front = most-recently added/upserted; picker and settings render in this order.
    static let knownServers = "knownServers"

    /// `JellyfinServer.id` of the active server. Must resolve into a `knownServers` entry when present; cleared only when the last server is removed.
    static let activeServerID = "activeServerID"

    /// Active user's display name, written beside every session save so restore can render the profile header before /Users/Me lands. Centralized key: scattered literals once let a typo split the active-user identity.
    static let activeUserName = "activeUserName"
    /// Active user's avatar PrimaryImageTag, same lifecycle as `activeUserName`.
    static let activeUserImageTag = "activeUserImageTag"

    /// JSON `[String: LiveDirectStreamMemory.Entry]` keyed by `userID|channelID`: the provider URL each live channel last direct-played from. Keychain, not UserDefaults, because an Xtream-style upstream carries the provider's credentials in its path.
    static let liveDirectStreams = "liveDirectStreams"

    /// JSON `GuardianPINCrypto.Blob`. Device-global (one household PIN, not per-server); absent = no PIN. Keychain so wiping UserDefaults can't reset the lock or its throttle.
    static let guardianPINBlob = "guardianPINBlob"

    /// JSON `GuardianPINThrottle` (failed-attempt count + lockout deadline). Device-global, keychain to resist tampering.
    static let guardianPINThrottle = "guardianPINThrottle"

    /// JSON `GuardianPINThrottle` for the Guardian PIN typed at a profile door. One for all of them:
    /// every profile door also takes the Guardian PIN, and a counter per door multiplied its budget.
    static let guardianPINProfileDoorThrottle = "guardianPINProfileDoorThrottle"

    /// JSON `GuardianPINCrypto.Blob` for one profile's own entry PIN. Absent means the door takes
    /// the Guardian PIN only. Keyed by the same pair the lock roles are keyed by.
    static func profilePINBlob(serverID: String, userID: String) -> String {
        "profilePINBlob_\(serverID)_\(userID)"
    }

    /// JSON `GuardianPINThrottle` for one profile's entry door. Per door, so guessing at one profile
    /// cannot lock the household out of the Guardian PIN.
    static func profilePINThrottle(serverID: String, userID: String) -> String {
        "profilePINThrottle_\(serverID)_\(userID)"
    }

    /// JSON `TraktSession` for one profile on this device. Never synced: Trakt refresh tokens are
    /// single use, so a pair shared between devices dies at the first refresh on either.
    static func traktSession(serverID: String, userID: String) -> String {
        "traktSession_\(serverID)_\(userID)"
    }

    static func seerrSession(serverID: String) -> String {
        "seerrSession_\(serverID)"
    }

    /// JSON `RememberedSeerrSession` per Jellyfin profile, so a profile switch restores each user's own Seerr login instead of re-auth.
    static func rememberedSeerr(jellyfinServerID: String, jellyfinUserID: String) -> String {
        "rememberedSeerr_\(jellyfinServerID)_\(jellyfinUserID)"
    }

    /// JSON `[String: String]`, `host:port` to the SHA-256 of the certificate the user accepted for
    /// it. Keychain rather than UserDefaults for the same reason the PIN blob is: this is the record
    /// of a security decision, and wiping defaults must not silently widen what the app trusts.
    static let trustedCertificates = "trustedCertificates"

    /// The one shared-session blob the TopShelf extension reads. Under `runs-as-current-user` the
    /// keychain is already per tvOS user, so a second per-user key would be a partition inside a
    /// partition. The `_default` suffix is kept verbatim: existing installs carry that account name.
    static let sharedSession = "tvOSSession_default"
}
