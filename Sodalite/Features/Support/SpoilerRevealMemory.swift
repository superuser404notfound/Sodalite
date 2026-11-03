import Foundation
import Observation

/// Sodalite#50. Items the user manually revealed. Device-local (UserDefaults), mirrored to
/// CloudKit by a union merge over `entries` and `hiddenAt`; read/write via
/// `DependencyContainer.spoilerRevealMemory`.
///
/// Sodalite#222. Hiding one again never removes its reveal: the union would bring a removed key
/// back from the other device, and older builds union `entries` without knowing `hiddenAt`. A key
/// counts as revealed while its reveal is newer than its hide, so revealing again simply wins.
@Observable
@MainActor
final class SpoilerRevealMemory {

    /// Bounded like `TrackSelectionMemory`. Eviction is harmless here: an entry that old belongs
    /// to a title the user has long since played, which the policy reveals anyway.
    nonisolated static let maxEntries = 500

    private static let storageKey = "spoiler.revealed"
    private static let hiddenStorageKey = "spoiler.hidden"

    /// Reveal key ("<userID>|<itemID>") to reveal time. The cloud sync layer observes this, so
    /// every mutation replaces the dictionary rather than mutating it in place.
    private(set) var entries: [String: Date]

    /// Reveal key to the time the user hid it again. Same replace-only rule as `entries`.
    private(set) var hiddenAt: [String: Date]

    /// Kept in step with `entries` instead of computed: the policy reads it once per card body,
    /// and `Set(entries.keys)` would allocate there on every frame.
    private(set) var revealedKeys: Set<String>

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        let loaded = Self.load(Self.storageKey, from: store)
        let hidden = Self.load(Self.hiddenStorageKey, from: store)
        self.entries = loaded
        self.hiddenAt = hidden
        self.revealedKeys = Self.effectiveKeys(entries: loaded, hiddenAt: hidden)
    }

    func isRevealed(_ key: String) -> Bool { revealedKeys.contains(key) }

    /// Stamped past an earlier hide for the same clock-skew reason as `hideKeys`.
    func reveal(_ key: String, now: Date = Date()) {
        var updated = entries
        updated[key] = hiddenAt[key].map { max(now, $0.addingTimeInterval(0.001)) } ?? now
        apply(Self.capped(updated), hiddenAt: hiddenAt)
    }

    /// Sodalite#222. A key that is not revealed has nothing to hide, so nothing is written for it.
    func hide(_ key: String, now: Date = Date()) {
        hideKeys([key], now: now)
    }

    /// Hides every reveal under one profile's prefix ("<userID>|").
    func hideAll(userID: String, now: Date = Date()) {
        let prefix = "\(userID)|"
        hideKeys(revealedKeys.filter { $0.hasPrefix(prefix) }, now: now)
    }

    /// Never stamped before the reveal: one written by a device whose clock runs ahead would
    /// otherwise outlive the hide, and the button would do nothing.
    private func hideKeys<Keys: Sequence<String>>(_ keys: Keys, now: Date) {
        var updated = hiddenAt
        for key in keys {
            guard isRevealed(key), let revealedAt = entries[key] else { continue }
            updated[key] = max(now, revealedAt)
        }
        guard updated != hiddenAt else { return }
        apply(entries, hiddenAt: updated)
    }

    /// Cloud apply path: the merged set replaces the local one wholesale. A nil `hiddenAt` comes
    /// from a payload that predates it and says nothing about hides, so the local ones stay.
    func replaceAll(_ incoming: [String: Date], hiddenAt incomingHidden: [String: Date]? = nil) {
        apply(Self.capped(incoming), hiddenAt: incomingHidden ?? hiddenAt)
    }

    /// nonisolated: a pure function over its argument, and the cloud merge needs it.
    nonisolated static func capped(_ entries: [String: Date]) -> [String: Date] {
        guard entries.count > maxEntries else { return entries }
        let kept = entries
            .sorted { $0.value > $1.value }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// A hide older than its reveal can never matter again, since a reveal time only ever grows,
    /// so it is dropped. A hide without a local reveal stays: the cloud may still carry that reveal.
    nonisolated static func prunedHides(_ hiddenAt: [String: Date], entries: [String: Date]) -> [String: Date] {
        capped(hiddenAt.filter { key, hidAt in
            guard let revealedAt = entries[key] else { return true }
            return hidAt >= revealedAt
        })
    }

    /// Ties go to the hide: it can only have been written after the reveal it was hiding.
    nonisolated static func effectiveKeys(entries: [String: Date], hiddenAt: [String: Date]) -> Set<String> {
        Set(entries.compactMap { key, revealedAt in
            guard let hidAt = hiddenAt[key] else { return key }
            return revealedAt > hidAt ? key : nil
        })
    }

    private func apply(_ updated: [String: Date], hiddenAt updatedHidden: [String: Date]) {
        entries = updated
        hiddenAt = Self.prunedHides(updatedHidden, entries: updated)
        revealedKeys = Self.effectiveKeys(entries: entries, hiddenAt: hiddenAt)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            store.set(data, forKey: Self.storageKey)
        }
        if let data = try? JSONEncoder().encode(hiddenAt) {
            store.set(data, forKey: Self.hiddenStorageKey)
        }
    }

    private static func load(_ key: String, from store: UserDefaults) -> [String: Date] {
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return decoded
    }
}
