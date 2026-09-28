import Foundation

/// Which queued downloads may start now (Sodalite#81). A transcode costs the server a live encode,
/// so only one runs; originals are plain file reads and two share the line fairly.
enum DownloadScheduler {
    static let maxOriginal = 2
    static let maxTranscode = 1

    static func toStart(queued: [DownloadManifest], running: [DownloadManifest]) -> [String] {
        var originals = running.filter { $0.route == .original }.count
        var transcodes = running.filter { $0.route == .transcode }.count
        var result: [String] = []
        for manifest in queued.sorted(by: { $0.createdAt < $1.createdAt }) {
            switch manifest.route {
            case .original where originals < maxOriginal:
                originals += 1
                result.append(manifest.itemID)
            case .transcode where transcodes < maxTranscode:
                transcodes += 1
                result.append(manifest.itemID)
            default:
                continue
            }
        }
        return result
    }
}

/// Carried in `URLSessionTask.taskDescription`, the only thing a background task still knows about
/// itself after the app was killed and relaunched.
nonisolated struct DownloadTaskTag: Hashable, Sendable {
    let serverID: String
    let userID: String
    let itemID: String
    let fileExtension: String

    var encoded: String { ["sodalite-dl", serverID, userID, itemID, fileExtension].joined(separator: "|") }

    init(serverID: String, userID: String, itemID: String, fileExtension: String) {
        self.serverID = serverID
        self.userID = userID
        self.itemID = itemID
        self.fileExtension = fileExtension
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "sodalite-dl" else { return nil }
        self.init(serverID: parts[1], userID: parts[2], itemID: parts[3], fileExtension: parts[4])
    }
}
