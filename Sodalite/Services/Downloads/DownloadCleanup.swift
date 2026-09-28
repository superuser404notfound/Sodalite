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

extension DependencyContainer {
    /// Called from the explicit user actions only (log out, remove a server, forget or sign a profile
    /// out everywhere, reset), never from `removeServer` / `forgetUser` themselves: iCloud applies a
    /// removal made on another device through those, and a token the server rejected drops the
    /// profile through them too, and neither may take a phone's downloads with it.
    func purgeDownloads(_ scope: DownloadCleanupScope) {
        let store = downloadStore
        let manager = downloadManager
        Task { await DownloadCleanup.perform(scope, store: store, manager: manager) }
    }

    /// The confirmation text with the downloads that go along, when there are any.
    func messageWithDownloadWarning(_ base: String, scope: DownloadCleanupScope) -> String {
        guard let warning = DownloadCleanup.warning(for: DownloadCleanup.usage(scope, store: downloadStore)) else { return base }
        return base + "\n\n" + warning
    }
}

import SwiftUI

extension View {
    /// Asks before forgetting a profile that still has downloads on this device (Sodalite#81). A
    /// profile without any is forgotten at once, as before: the question exists for the files.
    func confirmsForgettingDownloads(_ pending: Binding<RememberedUser?>, message: @escaping (RememberedUser) -> String,
                                     perform: @escaping (RememberedUser) -> Void) -> some View {
        alert(
            pending.wrappedValue.map { String(localized: "profile.forget.confirm \($0.name)") } ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { user in
            Button("profile.forget.confirm.short", role: .destructive) { perform(user) }
            Button("common.cancel", role: .cancel) {}
        } message: { user in
            Text(verbatim: message(user))
        }
    }
}
