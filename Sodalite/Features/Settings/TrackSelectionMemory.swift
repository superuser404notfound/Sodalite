import Foundation
import Observation

/// Per-title memory of manual audio and subtitle picks (Sodalite#46). Device-local
/// (UserDefaults), mirrored to CloudKit by a union merge over `entries`; read/write via
/// `DependencyContainer.trackSelectionMemory`.
@Observable
@MainActor
final class TrackSelectionMemory {

    /// Bounded so a long library cannot grow the blob without limit; eviction drops the
    /// least recently changed entries. nonisolated so `capped` and the cloud merge can read it.
    nonisolated static let maxEntries = 500

    private static let storageKey = "playback.trackSelectionMemory"

    /// Scope key to entry. The cloud sync layer observes this, so every mutation replaces
    /// the dictionary rather than mutating it in place.
    private(set) var entries: [String: TrackMemoryEntry]

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: TrackMemoryEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    /// Episodes share their series' entry so a pick carries to the next episode. The user
    /// id keeps two profiles on one server apart. Plain strings, not a JellyfinItem: the
    /// store has no business knowing the Jellyfin model.
    static func scopeKey(userID: String, itemID: String, seriesID: String?) -> String {
        if let seriesID, !seriesID.isEmpty {
            return "\(userID)|series|\(seriesID)"
        }
        return "\(userID)|item|\(itemID)"
    }

    /// The per-file key: an episode's subtitle timing belongs to its release, not to its series.
    static func itemKey(userID: String, itemID: String) -> String {
        scopeKey(userID: userID, itemID: itemID, seriesID: nil)
    }

    func entry(for key: String) -> TrackMemoryEntry? { entries[key] }

    func recordSubtitle(_ value: RememberedSubtitle, for key: String, now: Date = Date()) {
        var entry = entries[key] ?? TrackMemoryEntry(subtitle: nil, audio: nil, updatedAt: now)
        entry.subtitle = value
        entry.updatedAt = now
        write(entry, for: key)
    }

    func recordAudio(_ signature: TrackSignature, for key: String, now: Date = Date()) {
        var entry = entries[key] ?? TrackMemoryEntry(subtitle: nil, audio: nil, updatedAt: now)
        entry.audio = signature
        entry.updatedAt = now
        write(entry, for: key)
    }

    func recordSubtitleOffset(_ seconds: Double, for key: String, now: Date = Date()) {
        var entry = entries[key] ?? TrackMemoryEntry(subtitle: nil, audio: nil, updatedAt: now)
        entry.subtitleOffset = seconds == 0 ? nil : seconds
        entry.updatedAt = now
        write(entry, for: key)
    }

    /// Cloud apply path: the merged set replaces the local one wholesale.
    func replaceAll(_ incoming: [String: TrackMemoryEntry]) {
        entries = Self.capped(incoming)
        persist()
    }

    /// nonisolated: a pure function over its argument, and the cloud merge needs it.
    nonisolated static func capped(_ entries: [String: TrackMemoryEntry]) -> [String: TrackMemoryEntry] {
        guard entries.count > maxEntries else { return entries }
        let kept = entries
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func write(_ entry: TrackMemoryEntry, for key: String) {
        var updated = entries
        updated[key] = entry
        entries = Self.capped(updated)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        store.set(data, forKey: Self.storageKey)
    }
}
