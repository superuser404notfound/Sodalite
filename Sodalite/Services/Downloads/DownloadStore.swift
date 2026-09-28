import Foundation
import Observation

/// The on-disk truth of the downloads (Sodalite#81). Everything offline reads this and nothing else.
/// `items` holds the ACTIVE profile only, so a profile never sees another profile's downloads.
@MainActor @Observable
final class DownloadStore {
    let paths: DownloadPaths
    private(set) var activeProfile: ProfileKey?
    private(set) var items: [String: DownloadedItem] = [:]

    @ObservationIgnored private let fileManager = FileManager.default

    init(paths: DownloadPaths) {
        self.paths = paths
    }

    func activate(_ profile: ProfileKey?) {
        activeProfile = profile
        items = profile.map(loadItems(of:)) ?? [:]
    }

    func item(_ itemID: String) -> DownloadedItem? { items[itemID] }

    func completedItem(_ itemID: String) -> DownloadedItem? {
        guard let item = items[itemID], item.manifest.state == .complete || item.manifest.state == .missingOnServer,
              let media = item.mediaURL, fileManager.fileExists(atPath: media.path) else { return nil }
        return item
    }

    @discardableResult
    func create(_ manifest: DownloadManifest, snapshot: DownloadSnapshot) throws -> DownloadedItem {
        guard let profile = activeProfile else { throw CocoaError(.fileWriteNoPermission) }
        try ensureRoot()
        let directory = paths.itemDirectory(serverID: profile.serverID, userID: profile.userID, itemID: manifest.itemID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(DownloadPaths.snapshotName), options: .atomic)
        try write(manifest, to: directory)
        let item = DownloadedItem(manifest: manifest, snapshot: snapshot, directory: directory)
        items[manifest.itemID] = item
        return item
    }

    func update(itemID: String, _ mutate: (inout DownloadManifest) -> Void) throws {
        guard var item = items[itemID] else { return }
        mutate(&item.manifest)
        try write(item.manifest, to: item.directory)
        items[itemID] = item
    }

    func delete(itemID: String) throws {
        guard let item = items.removeValue(forKey: itemID) else { return }
        try removeIfPresent(item.directory)
    }

    func deleteProfile(serverID: String, userID: String) throws {
        try removeIfPresent(paths.profileDirectory(serverID: serverID, userID: userID))
        if activeProfile?.serverID == serverID, activeProfile?.userID == userID { items = [:] }
    }

    func deleteServer(serverID: String) throws {
        try removeIfPresent(paths.serverDirectory(serverID: serverID))
        if activeProfile?.serverID == serverID { items = [:] }
    }

    func deleteAll() throws {
        try removeIfPresent(paths.root)
        items = [:]
    }

    struct Usage: Equatable, Sendable {
        var items: Int
        var bytes: Int64
    }

    func usage(serverID: String, userID: String) -> Usage {
        measure(paths.profileDirectory(serverID: serverID, userID: userID), depth: 1)
    }

    func usage(serverID: String) -> Usage {
        measure(paths.serverDirectory(serverID: serverID), depth: 2)
    }

    func totalUsage() -> Usage {
        measure(paths.root, depth: 3)
    }

    // MARK: - Private

    private func loadItems(of profile: ProfileKey) -> [String: DownloadedItem] {
        let dir = paths.profileDirectory(serverID: profile.serverID, userID: profile.userID)
        guard let children = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: DownloadedItem] = [:]
        for child in children {
            guard let manifestData = try? Data(contentsOf: child.appendingPathComponent(DownloadPaths.manifestName)),
                  let snapshotData = try? Data(contentsOf: child.appendingPathComponent(DownloadPaths.snapshotName)),
                  let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: manifestData),
                  let snapshot = try? JSONDecoder().decode(DownloadSnapshot.self, from: snapshotData) else { continue }
            result[manifest.itemID] = DownloadedItem(manifest: manifest, snapshot: snapshot, directory: child)
        }
        return result
    }

    private func write(_ manifest: DownloadManifest, to directory: URL) throws {
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(DownloadPaths.manifestName), options: .atomic)
    }

    private func ensureRoot() throws {
        var root = paths.root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Items are the directories `depth` levels below `url` that hold a manifest.
    private func measure(_ url: URL, depth: Int) -> Usage {
        var usage = Usage(items: 0, bytes: 0)
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return usage }
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            usage.bytes += Int64(values?.totalFileAllocatedSize ?? 0)
            if file.lastPathComponent == DownloadPaths.manifestName,
               walker.level == depth + 1 { usage.items += 1 }
        }
        return usage
    }
}
