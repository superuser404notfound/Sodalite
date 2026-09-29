import Foundation

extension DependencyContainer {
    /// Sodalite#81. The background session is created here, on every launch, so a relaunch for
    /// background events finds its session before the first event is delivered.
    func makeDownloadManager() -> DownloadManager {
        let relay = DownloadEventRelay()
        let delegate = DownloadSessionDelegate(paths: downloadStore.paths, relay: relay)
        let manager = DownloadManager(store: downloadStore,
                                      backend: JellyfinDownloadBackend(container: self),
                                      transport: BackgroundDownloadTransport(delegate: delegate))
        relay.attach { [weak manager] event in
            Task { @MainActor in await manager?.handle(event: event) }
        }
        return manager
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
        // and the manifests being reconciled are the store's.
        let sync = DownloadProgressSync(store: downloadStore, service: service, userID: profile.userID)
        downloadSyncTask = Task { [weak self] in
            await sync.run()
            self?.downloadSyncTask = nil
        }
    }
}
