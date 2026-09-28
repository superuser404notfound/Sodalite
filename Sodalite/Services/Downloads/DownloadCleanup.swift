import Foundation

enum DownloadCleanupScope: Equatable {
    case everything
    case server(String)
    case profile(serverID: String, userID: String)
}

/// Downloads leave with the account that made them (Sodalite#81): files of a profile nobody can sign
/// into any more would only be reachable by deleting the app.
@MainActor
enum DownloadCleanup {
    static func usage(_ scope: DownloadCleanupScope, store: DownloadStore) -> DownloadStore.Usage {
        switch scope {
        case .everything: store.totalUsage()
        case .server(let id): store.usage(serverID: id)
        case .profile(let serverID, let userID): store.usage(serverID: serverID, userID: userID)
        }
    }

    static func perform(_ scope: DownloadCleanupScope, store: DownloadStore, manager: DownloadManager?) async {
        if let manager, let active = store.activeProfile, covers(scope, active) {
            for item in store.items.values where item.manifest.state != .complete && item.manifest.state != .missingOnServer {
                await manager.cancel(itemID: item.id)
            }
        }
        switch scope {
        case .everything: try? store.deleteAll()
        case .server(let id): try? store.deleteServer(serverID: id)
        case .profile(let serverID, let userID): try? store.deleteProfile(serverID: serverID, userID: userID)
        }
    }

    static func warning(for usage: DownloadStore.Usage) -> String? {
        guard usage.items > 0 else { return nil }
        return String(localized: "downloads.cleanup.warning \(usage.items) \(usage.bytes.formatted(.byteCount(style: .file)))")
    }

    private static func covers(_ scope: DownloadCleanupScope, _ profile: ProfileKey) -> Bool {
        switch scope {
        case .everything: true
        case .server(let id): profile.serverID == id
        case .profile(let serverID, let userID): profile.serverID == serverID && profile.userID == userID
        }
    }
}
