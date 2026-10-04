import Foundation

/// The bridge between the per-profile settings registry and the rest of the container: which
/// profiles exist on this device, and how a profile record is collected and applied.
extension DependencyContainer {

    var activeProfileKey: ProfileKey? { appState?.profileKey }

    /// Every profile this device knows on every known server: the remembered ones plus the one
    /// each server was last signed in with, which may not be remembered yet.
    func profileKeysOnThisDevice() -> [ProfileKey] {
        var keys: [ProfileKey] = []
        for server in listKnownServers() {
            var userIDs = listRememberedUsers(serverID: server.id).map(\.id)
            if let signedIn = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)),
               !userIDs.contains(signedIn) {
                userIDs.append(signedIn)
            }
            keys += userIDs.map { ProfileKey(serverID: server.id, userID: $0) }
        }
        return keys
    }

    /// The home rows a server record mirrors for builds before per-profile settings: those of the
    /// profile this device last signed in with on that server, else the server's pre-change rows.
    func legacyHomeScope(serverID: String) -> String {
        guard let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID)) else {
            return serverID
        }
        let key = ProfileKey(serverID: serverID, userID: userID)
        return profileSettings.hasValues(key) ? key.storageScope : serverID
    }

    /// nil for a profile this device holds no values for, so a queued save of it is dropped.
    func collectProfilePayload(_ kind: ProfileRecordKind, key: ProfileKey, stamp: Date) -> ProfileSyncPayload? {
        guard profileSettings.hasValues(key) else { return nil }
        let settings = profileSettings.settings(for: key)
        switch kind {
        case .playback:
            return .playback(ProfilePlaybackPayload(collecting: settings.playback, stamp: stamp))
        case .appearance:
            return .appearance(ProfileAppearancePayload(collecting: settings.appearance, stamp: stamp))
        case .home:
            return .home(ProfileHomeStore.collect(scope: key.storageScope, stamp: stamp))
        }
    }

    /// A profile this device has never seen is seeded first, so the kinds this record does not carry
    /// start from a copy rather than from factory values.
    func applyProfilePayload(_ payload: ProfileSyncPayload, key: ProfileKey) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        let settings = profileSettings.settings(for: key)
        switch payload {
        case .playback(let p):
            p.apply(to: settings.playback)
        case .appearance(let a):
            a.apply(to: settings.appearance)
        case .home(let h):
            ProfileHomeStore.apply(h, scope: key.storageScope)
            if key == activeProfileKey {
                // The record carries Combine servers, so who takes part may have changed (Sodalite#85).
                refreshSessionRegistry()
                NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
            }
        }
        profileSettings.noteCloudApplied(key, payload.kind)
        sessionNote("cloud record for profile \(key.fingerprint) \(payload.kind.rawValue) applied.")
    }
}
