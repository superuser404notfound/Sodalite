import Foundation
import AetherEngine

/// Remembers each title's picture area (Sodalite#118), so a Resume or the next launch zooms before
/// the first frame instead of after a scan. One small JSON file in `Library/Caches`; the oldest
/// entries go once `capacity` is reached. Losing it costs one scan, nothing else.
final class PictureAreaCache: @unchecked Sendable {
    static let shared = PictureAreaCache(
        fileURL: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                  ?? FileManager.default.temporaryDirectory).appendingPathComponent("picture-areas.json"),
        writesAsynchronously: true)

    static func key(serverID: String?, itemID: String, mediaSourceID: String) -> String {
        "\(serverID ?? "")|\(itemID)|\(mediaSourceID)"
    }

    private struct Entry: Codable {
        var area: PictureArea
        var written: Date
    }

    private let fileURL: URL
    private let capacity: Int
    private let lock = NSLock()
    private var loaded: [String: Entry]?
    private var entries: [String: Entry] {
        get {
            if let loaded { return loaded }
            let read = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            loaded = read
            return read
        }
        set { loaded = newValue }
    }
    /// The shared cache encodes and writes on its own serial queue, off the main thread; the in-memory
    /// value answers reads at once. Tests use the synchronous default.
    private let writeQueue: DispatchQueue?

    init(fileURL: URL, capacity: Int = 2000, writesAsynchronously: Bool = false) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        writeQueue = writesAsynchronously ? DispatchQueue(label: "de.superuser404.Sodalite.picture-areas", qos: .utility) : nil
        // Decode up front on the queue, so the first read on the main thread finds it loaded.
        writeQueue?.async { [self] in
            lock.lock()
            _ = entries
            lock.unlock()
        }
    }

    func area(for key: String) -> PictureArea? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.area
    }

    /// Waits for queued writes; for tests.
    func flush() { writeQueue?.sync {} }

    func store(_ area: PictureArea, for key: String) {
        lock.lock()
        // Strictly increasing stamps, so two writes inside one clock tick still evict in order.
        let last = entries.values.map(\.written).max() ?? .distantPast
        entries[key] = Entry(area: area, written: max(Date(), last.addingTimeInterval(0.001)))
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.written < $1.value.written })?.key {
            entries.removeValue(forKey: oldest)
        }
        let snapshot = entries
        lock.unlock()
        let url = fileURL
        let write = {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        if let writeQueue { writeQueue.async(execute: write) } else { write() }
    }
}
