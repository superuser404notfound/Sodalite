import Foundation

protocol UserItemDataServing: Sendable {
    func userData(itemID: String, userID: String) async throws -> UserItemData
    func updateUserData(itemID: String, userID: String, positionTicks: Int64, played: Bool, lastPlayed: Date) async throws
}

/// Jellyfin writes seven fractional digits, which `ISO8601DateFormatter` rejects at any setting.
enum JellyfinDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        var trimmed = raw
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[dot...].drop { $0 == "." || $0.isNumber }
            trimmed = String(raw[..<dot]) + tail
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum DownloadSyncDecision: Equatable {
    case push, adopt, nothing
}

/// Reconciles what local sessions wrote into the manifests with the server's UserData (Sodalite#81).
/// The newer `LastPlayedDate` wins in both directions, so a film finished on the TV is not rewound by
/// a phone that watched its first ten minutes offline a day earlier.
@MainActor
final class DownloadProgressSync {
    private let store: DownloadStore
    private let service: any UserItemDataServing
    private let userID: String
    private let now: () -> Date
    private var isRunning = false

    init(store: DownloadStore, service: any UserItemDataServing, userID: String, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.service = service
        self.userID = userID
        self.now = now
    }

    static func decide(local: DownloadLocalProgress, server: UserItemData) -> DownloadSyncDecision {
        guard let localDate = local.lastPlayed else { return .adopt }
        guard let serverDate = JellyfinDate.parse(server.lastPlayedDate) else { return .push }
        // Second precision: the server rounds what we send.
        let l = localDate.timeIntervalSince1970.rounded(.down)
        let s = serverDate.timeIntervalSince1970.rounded(.down)
        if l > s { return .push }
        if s > l { return .adopt }
        return .nothing
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        for item in store.items.values where item.manifest.state == .complete || item.manifest.state == .missingOnServer {
            let id = item.manifest.itemID
            guard let server = try? await service.userData(itemID: id, userID: userID) else { continue }
            let local = item.manifest.progress
            switch Self.decide(local: local, server: server) {
            case .push:
                guard let lastPlayed = local.lastPlayed,
                      (try? await service.updateUserData(itemID: id, userID: userID, positionTicks: local.positionTicks,
                                                         played: local.played, lastPlayed: lastPlayed)) != nil else { continue }
                stamp(id)
                NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil, userInfo: [
                    PlaybackProgressKey.itemID: id, PlaybackProgressKey.positionTicks: local.positionTicks,
                ])
            case .adopt:
                try? store.update(itemID: id) {
                    $0.progress.positionTicks = server.playbackPositionTicks ?? 0
                    $0.progress.played = server.played ?? false
                    $0.progress.lastPlayed = JellyfinDate.parse(server.lastPlayedDate)
                    $0.progress.lastSyncedAt = now()
                }
            case .nothing:
                stamp(id)
            }
        }
    }

    private func stamp(_ id: String) {
        let date = now()
        try? store.update(itemID: id) { $0.progress.lastSyncedAt = date }
    }
}
