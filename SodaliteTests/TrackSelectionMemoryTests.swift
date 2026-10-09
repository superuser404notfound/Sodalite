import Testing
import Foundation
@testable import Sodalite

/// Per-title memory of manual audio and subtitle picks (Sodalite#46). Episodes share
/// their series' entry so a pick carries to the next episode; everything else is keyed
/// by item. The user id is part of the key so two profiles on one server stay separate.
@MainActor
struct TrackSelectionMemoryTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "TrackSelectionMemoryTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    private let signature = TrackSignature(language: "ger", isForced: false, isExternal: false,
                                           codec: "subrip", descriptor: nil, channels: nil)

    @Test("an episode is keyed by its series, a movie by itself")
    func scopeKeys() {
        #expect(TrackSelectionMemory.scopeKey(userID: "u1", itemID: "e1", seriesID: "s9")
                == "u1|series|s9")
        #expect(TrackSelectionMemory.scopeKey(userID: "u1", itemID: "m1", seriesID: nil)
                == "u1|item|m1")
    }

    @Test("an episode without a series id falls back to its own item id")
    func scopeKeyFallsBackToItem() {
        #expect(TrackSelectionMemory.scopeKey(userID: "u1", itemID: "e1", seriesID: "")
                == "u1|item|e1")
    }

    @Test("two profiles keep separate memories for the same title")
    func scopeKeysAreUserScoped() {
        #expect(TrackSelectionMemory.scopeKey(userID: "u1", itemID: "m1", seriesID: nil)
                != TrackSelectionMemory.scopeKey(userID: "u2", itemID: "m1", seriesID: nil))
    }

    @Test("a recorded subtitle survives a fresh store on the same defaults")
    func subtitleRoundTrip() {
        let store = defaults(#function)
        let memory = TrackSelectionMemory(store: store)
        memory.recordSubtitle(.track(signature), for: "k", now: Date(timeIntervalSince1970: 10))
        #expect(TrackSelectionMemory(store: store).entry(for: "k")?.subtitle == .track(signature))
    }

    @Test("off round-trips as an explicit choice")
    func offRoundTrip() {
        let store = defaults(#function)
        let memory = TrackSelectionMemory(store: store)
        memory.recordSubtitle(.off, for: "k", now: Date(timeIntervalSince1970: 10))
        #expect(TrackSelectionMemory(store: store).entry(for: "k")?.subtitle == .off)
    }

    @Test("recording audio leaves the remembered subtitle intact")
    func axesAreIndependent() {
        let memory = TrackSelectionMemory(store: defaults(#function))
        memory.recordSubtitle(.off, for: "k", now: Date(timeIntervalSince1970: 10))
        memory.recordAudio(signature, for: "k", now: Date(timeIntervalSince1970: 20))
        let entry = memory.entry(for: "k")
        #expect(entry?.subtitle == .off)
        #expect(entry?.audio == signature)
        #expect(entry?.updatedAt == Date(timeIntervalSince1970: 20))
    }

    @Test("a subtitle offset round-trips and leaves the track picks alone")
    func subtitleOffsetRoundTrip() {
        let store = defaults(#function)
        let memory = TrackSelectionMemory(store: store)
        memory.recordSubtitle(.off, for: "k", now: Date(timeIntervalSince1970: 10))
        memory.recordSubtitleOffset(1.5, for: "k", now: Date(timeIntervalSince1970: 20))
        let entry = TrackSelectionMemory(store: store).entry(for: "k")
        #expect(entry?.subtitleOffset == 1.5)
        #expect(entry?.subtitle == .off)
        #expect(entry?.updatedAt == Date(timeIntervalSince1970: 20))
    }

    @Test("a zero offset is stored as no offset")
    func zeroOffsetClears() {
        let memory = TrackSelectionMemory(store: defaults(#function))
        memory.recordSubtitleOffset(0.4, for: "k", now: Date(timeIntervalSince1970: 10))
        memory.recordSubtitleOffset(0, for: "k", now: Date(timeIntervalSince1970: 20))
        #expect(memory.entry(for: "k")?.subtitleOffset == nil)
    }

    /// The offset belongs to one file, so an episode keys it by itself, never by its series.
    @Test("the offset key is the item, even for an episode")
    func offsetKeyIgnoresSeries() {
        #expect(TrackSelectionMemory.itemKey(userID: "u1", itemID: "e1") == "u1|item|e1")
    }

    /// Entries written before the field existed carry no `subtitleOffset` key at all.
    @Test("an entry from an older build decodes without an offset")
    func legacyEntryDecodes() throws {
        let json = #"{"subtitle":{"off":{}},"updatedAt":0}"#
        let entry = try JSONDecoder().decode(TrackMemoryEntry.self, from: Data(json.utf8))
        #expect(entry.subtitleOffset == nil)
        #expect(entry.subtitle == .off)
    }

    @Test("the store caps itself by evicting the oldest entries")
    func capEviction() {
        let memory = TrackSelectionMemory(store: defaults(#function))
        for i in 0...TrackSelectionMemory.maxEntries {
            memory.recordSubtitle(.off, for: "k\(i)", now: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(memory.entries.count == TrackSelectionMemory.maxEntries)
        #expect(memory.entry(for: "k0") == nil)
        #expect(memory.entry(for: "k\(TrackSelectionMemory.maxEntries)") != nil)
    }

    @Test("replaceAll caps what it is handed")
    func replaceAllCaps() {
        let memory = TrackSelectionMemory(store: defaults(#function))
        var incoming: [String: TrackMemoryEntry] = [:]
        for i in 0...TrackSelectionMemory.maxEntries {
            incoming["k\(i)"] = TrackMemoryEntry(subtitle: .off, audio: nil,
                                                 updatedAt: Date(timeIntervalSince1970: Double(i)))
        }
        memory.replaceAll(incoming)
        #expect(memory.entries.count == TrackSelectionMemory.maxEntries)
        #expect(memory.entry(for: "k0") == nil)
    }

    @Test("the remember toggle defaults to on")
    func togglesDefaultOn() {
        #expect(PlaybackPreferences(store: defaults(#function)).rememberTrackSelections)
    }
}
