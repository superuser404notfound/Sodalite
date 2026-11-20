import Foundation

/// Directory layout of the download store (Sodalite#81). Nonisolated because the background session
/// delegate has to move a finished file into place before its callback returns.
nonisolated struct DownloadPaths: Sendable {
    let root: URL

    static let manifestName = "manifest.json"
    static let snapshotName = "snapshot.json"

    /// `Application Support/Downloads`. Not `Caches`: the system purges that under storage pressure,
    /// and a film that vanishes on the plane is the one failure this feature exists to prevent.
    static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Downloads", isDirectory: true)
    }

    func serverDirectory(serverID: String) -> URL {
        root.appendingPathComponent(Self.component(serverID), isDirectory: true)
    }

    func profileDirectory(serverID: String, userID: String) -> URL {
        serverDirectory(serverID: serverID).appendingPathComponent(Self.component(userID), isDirectory: true)
    }

    func itemDirectory(serverID: String, userID: String, itemID: String) -> URL {
        profileDirectory(serverID: serverID, userID: userID)
            .appendingPathComponent(Self.component(itemID), isDirectory: true)
    }

    /// Server, user and item ids are GUIDs, but they arrive from the network: nothing in one may
    /// climb out of the root.
    static func component(_ raw: String) -> String {
        let cleaned = raw.map { $0 == "/" || $0 == ":" ? "_" : $0 }
        let joined = String(cleaned)
        return joined.isEmpty || joined == "." || joined == ".." ? "_\(joined)" : joined
    }
}
