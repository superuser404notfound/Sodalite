import Foundation

extension DependencyContainer {
    /// Sodalite#81. The background session is created here, on every launch, so a relaunch for
    /// background events finds its session before the first event is delivered.
    func makeDownloadManager() -> DownloadManager {
        let delegate = DownloadSessionDelegate(paths: downloadStore.paths)
        let manager = DownloadManager(store: downloadStore,
                                      backend: JellyfinDownloadBackend(container: self),
                                      transport: BackgroundDownloadTransport(delegate: delegate))
        delegate.onEvent = { [weak manager] event in
            Task { @MainActor in await manager?.handle(event: event) }
        }
        delegate.onFinishEvents = {
            Task { @MainActor in
                DownloadRelaunch.pendingCompletionHandler?()
                DownloadRelaunch.pendingCompletionHandler = nil
            }
        }
        return manager
    }

    /// Points the store at the active profile and re-attaches to whatever the session still runs.
    func activateDownloads() {
        downloadStore.activate(appState?.profileKey)
        guard let downloadManager else { return }
        Task { await downloadManager.reattach() }
    }

    /// Hands offline progress back to the server. Safe to call often: a run already going is joined
    /// by nothing, and every item it touches is written on the main actor.
    func runDownloadSync() {
        guard let userID = activeUserID, !downloadStore.items.isEmpty,
              let service = jellyfinItemService as? UserItemDataServing else { return }
        let sync = DownloadProgressSync(store: downloadStore, service: service, userID: userID)
        Task { await sync.run() }
    }
}
