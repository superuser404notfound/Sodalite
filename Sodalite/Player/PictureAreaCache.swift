import Foundation
import AetherEngine

/// Remembers each title's picture area (Sodalite#118), so a Resume or the next launch zooms before
/// the first frame instead of after a scan. One small JSON file in `Library/Caches`; the oldest
/// entries go once `capacity` is reached. Losing it costs one scan, nothing else.
final class PictureAreaCache: @unchecked Sendable {
    static let shared = PictureAreaCache(
        fileURL: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                  ?? FileManager.default.temporaryDirectory).appendingPathComponent("picture-areas.json"))

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
    private var entries: [String: Entry]

    init(fileURL: URL, capacity: Int = 2000) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        entries = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func area(for key: String) -> PictureArea? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.area
    }

    func store(_ area: PictureArea, for key: String) {
        lock.lock()
        // Strictly increasing stamps, so two writes inside one clock tick still evict in order.
        let last = entries.values.map(\.written).max() ?? .distantPast
        entries[key] = Entry(area: area, written: max(Date(), last.addingTimeInterval(0.001)))
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.written < $1.value.written })?.key {
            entries.removeValue(forKey: oldest)
        }
        let data = try? JSONEncoder().encode(entries)
        lock.unlock()
        if let data { try? data.write(to: fileURL, options: .atomic) }
    }
}
