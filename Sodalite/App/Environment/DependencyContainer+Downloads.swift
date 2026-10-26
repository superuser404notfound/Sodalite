import Foundation

extension DependencyContainer {
    /// Sodalite#81. The background session is created here, on every launch, so a relaunch for
    /// background events finds its session before the first event is delivered.
    func makeDownloadManager() -> DownloadManager {
        let relay = DownloadEventRelay()
        let delegate = DownloadSessionDelegate(paths: downloadStore.paths, relay: relay)
        let manager = DownloadManager(store: downloadStore,
                                      backend: JellyfinDownloadBackend(container: self),
                                      transport: BackgroundDownloadTransport(delegate: delegate),
                                      secondaryBackend: { [weak self] serverID in
                                          guard let self, sessionRegistry.secondary(serverID: serverID) != nil else { return nil }
                                          return JellyfinDownloadBackend(container: self, serverID: serverID)
                                      })
        relay.attach { [weak manager] event in
            Task { @MainActor in await manager?.handle(event: event) }
        }
        return manager
    }

    /// Starts the system's progress activity for the downloads now running, where the system has
    /// one. iOS draws it in the Dynamic Island and on the Lock Screen; nothing else has the concept,
    /// and the transfers themselves are a background URLSession either way.
    ///
    /// Apple's rule for that task type is that it may only start from something the viewer just
    /// did, which is why this is called from the download, resume and retry buttons and nowhere
    /// else.
    func beginDownloadActivity() {
        #if os(iOS)
        downloadActivity?.begin()
        #endif
    }

    /// Points the store at the active profile and re-attaches to whatever the session still runs.
    func activateDownloads() {
        downloadStore.activate(appState?.profileKey)
        if let downloadManager { Task { await downloadManager.reattach() } }
        // The reachability verdict of a cold launch lands during session restore, before the store
        // knows its profile, so the sync it triggered found nothing. This is the one that counts.
        if appState?.serverReachability == .reachable { runDownloadSync() }
    }

    /// Hands offline progress back to the server. Safe to call often: a run already going is joined
    /// by nothing, and every item it touches is written on the main actor.
    func runDownloadSync() {
        guard downloadSyncTask == nil, let profile = downloadStore.activeProfile, !downloadStore.items.isEmpty,
              let service = jellyfinItemService as? UserItemDataServing else { return }
        // The store's profile, not the container's active user: during a switch they can disagree,
        // and the manifests being reconciled are the store's. A download from another server of a
        // combined Home reconciles with that server, as its user, while it takes part (Sodalite#202).
        let sync = DownloadProgressSync(store: downloadStore) { [weak self] originServerID in
            guard let originServerID else { return (service, profile.userID) }
            guard let session = self?.sessionRegistry.secondary(serverID: originServerID),
                  let secondary = session.itemService as? UserItemDataServing else { return nil }
            return (secondary, session.userID)
        }
        downloadSyncTask = Task { [weak self] in
            await sync.run()
            self?.downloadSyncTask = nil
        }
    }
}
