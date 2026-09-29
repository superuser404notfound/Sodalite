import Foundation

/// Putting this device back to a first-launch state. Log Out is the neighbouring action and stops
/// deliberately short of this: it drops credentials and servers, and keeps preferences, because
/// signing out of a server is no reason to lose a theme. A reset keeps nothing (Sodalite#76).
extension DependencyContainer {

    /// Clears every credential, server, preference, cache and log on this device, and leaves iCloud
    /// sync off until someone turns it on again.
    ///
    /// `deleteCloudCopy` also removes the copy in iCloud. Without it the zone still describes the
    /// same servers, and turning sync back on (Settings, or "Load from iCloud" on the first screen)
    /// hands them straight back; nothing turns it on by itself. With it, there is nothing left to
    /// come back from.
    func resetToFactoryState(deleteCloudCopy: Bool) async {
        sessionNote("reset: starting, deleteCloudCopy=\(deleteCloudCopy).")

        // Before the local wipe: deleting the zone needs the engine that clearSession tears down.
        if deleteCloudCopy {
            await cloudSync?.deleteCloudDataAndDisable()
            if case .error = cloudSync?.status {
                sessionNote("reset: the iCloud copy was NOT deleted; sync stays off, so it does not come back by itself.")
            }
        }

        // Sodalite#81: a reset device holds no downloads either; before clearSession, while running
        // transcodes can still be told to stop.
        await DownloadCleanup.perform(.everything, store: downloadStore, manager: downloadManager)

        // Servers, tokens, profiles, passwords, Seerr, and cloud sync off on this device.
        try? clearSession()
        clearSessionResidue()
        // clearSession scrubs session state; a reset owes nothing to anything. The Guardian PIN, its
        // throttle, the remembered live routes and whatever a later key adds all sit in the same
        // keychain service, so take the service rather than a list that would fall behind.
        try? keychainService.deleteAll()
        SharedSessionMirror.clearAll()
        LogTap.discardPersistedLog()
        Self.clearGroupCaches(keeping: [])

        // Preferences live in two places at once. The domain is what the next launch reads.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // The app group is its own domain: the TopShelf extension reads the accent out of it.
        UserDefaults(suiteName: Self.appGroupSuiteName)?
            .removePersistentDomain(forName: Self.appGroupSuiteName)
        // The wipe took the off switch Log Out had just written, and a missing key reads as on.
        cloudSync?.handleFactoryReset()
        // Per-profile stores are cached in memory like every other store here; without this the next
        // edit in a cached profile writes its pre-reset values back into the wiped domain.
        profileSettings.resetAll()
        profileSettings.device.reloadFromStore()

        // And the objects already in memory are what this session reads. They parsed their values at
        // launch and persist on write, so a wiped domain alone would leave the app wearing the old
        // theme until it is relaunched, and the next edit of any one setting would write a stale
        // neighbour back out.
        if let factory = SettingsStores.factoryDefaults() {
            for key in CloudSyncStoreKey.allCases {
                applySettingsPayload(collectSettingsPayload(key, stamp: .now, from: factory))
            }
        } else {
            sessionNote("reset: no scratch suite for the factory stores, preferences land on defaults at the next launch.")
        }

        // The bridges SodaliteApp keys on a value change: one that already held its default does
        // not fire, and the extension would read the wiped group domain against the app's value.
        TopShelfEnabled.write(profileSettings.device.showTopShelfRow)
        TopShelfArtwork.write(rawValue: profileSettings.device.topShelfImage.rawValue)
        TopShelfRefresher.invalidate()

        sessionNote("reset: done.")
    }

    /// What a session leaves on disk outside the keychain. Jellyfin carries the access token in the
    /// query of every image and stream URL, and the response and artwork caches are keyed by those
    /// URLs; `URLCache.shared` is what the Top Shelf pre-render fills. The group container holds the
    /// shelf's items and rendered artwork. Log Out and a reset both run this; the shelf's own log is
    /// diagnostics, not session data, and only a reset takes it.
    func clearSessionResidue() {
        clearCachedData()
        URLCache.shared.removeAllCachedResponses()
        Self.clearGroupCaches(keeping: [ShelfLogFile.fileName])
        sessionNote("session caches cleared: responses, artwork, shared URL cache, Top Shelf files.")
    }

    /// The group container's `Library/Caches`, the only place besides Preferences the extension
    /// can write on tvOS, so everything it keeps is in here.
    nonisolated static func clearGroupCaches(
        in directory: URL? = TopShelfCachePolicy.directory(),
        keeping kept: Set<String>
    ) {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for entry in entries where !kept.contains(entry) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// Shared with the TopShelf extension; see TopShelfCachePolicy.appGroup.
    static var appGroupSuiteName: String { "group.de.superuser404.Sodalite" }
}
