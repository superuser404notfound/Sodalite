import Foundation

extension DependencyContainer: TraktSessionStoring {

    func loadTraktSession(for profile: ProfileKey) -> TraktSession? {
        guard let data = try? keychainService.loadData(
            for: KeychainKeys.traktSession(serverID: profile.serverID, userID: profile.userID))
        else { return nil }
        return try? JSONDecoder().decode(TraktSession.self, from: data)
    }

    func saveTraktSession(_ session: TraktSession, for profile: ProfileKey) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? keychainService.save(data, for: KeychainKeys.traktSession(serverID: profile.serverID,
                                                                       userID: profile.userID))
    }

    func deleteTraktSession(for profile: ProfileKey) {
        try? keychainService.delete(for: KeychainKeys.traktSession(serverID: profile.serverID,
                                                                   userID: profile.userID))
    }

    /// Part of forgetting a profile. Local only: the token stays valid on Trakt until it expires,
    /// which is the same as every other credential `purgeUserCredentials` drops.
    func purgeTraktSession(for profile: ProfileKey) {
        deleteTraktSession(for: profile)
        TraktCacheStore.removeAll(profile)
    }
}
