import Testing
import Foundation
@testable import Sodalite

/// Items the user manually revealed (Sodalite#50). Bounded like TrackSelectionMemory, and
/// eviction is harmless: an entry that old belongs to a title the policy reveals anyway.
@MainActor
struct SpoilerRevealMemoryTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "SpoilerRevealMemoryTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("a reveal is readable and lands in revealedKeys")
    func revealWritesThrough() {
        let memory = SpoilerRevealMemory(store: defaults("write"))
        memory.reveal("u1|i1")
        #expect(memory.isRevealed("u1|i1"))
        #expect(memory.revealedKeys == ["u1|i1"])
        #expect(!memory.isRevealed("u1|i2"))
    }

    @Test("reveals survive a new instance over the same defaults")
    func revealPersists() {
        let store = defaults("persist")
        SpoilerRevealMemory(store: store).reveal("u1|i1")
        #expect(SpoilerRevealMemory(store: store).isRevealed("u1|i1"))
    }

    @Test("the cap evicts the oldest reveal")
    func capEvictsOldest() {
        let memory = SpoilerRevealMemory(store: defaults("cap"))
        for i in 0...SpoilerRevealMemory.maxEntries {
            memory.reveal("u1|i\(i)", now: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(memory.entries.count == SpoilerRevealMemory.maxEntries)
        #expect(!memory.isRevealed("u1|i0"))
        #expect(memory.isRevealed("u1|i\(SpoilerRevealMemory.maxEntries)"))
    }

    @Test("replaceAll swaps the set and caps the incoming one")
    func replaceAllCaps() {
        let memory = SpoilerRevealMemory(store: defaults("replace"))
        memory.reveal("u1|old")
        var incoming: [String: Date] = [:]
        for i in 0..<(SpoilerRevealMemory.maxEntries + 10) {
            incoming["u1|n\(i)"] = Date(timeIntervalSince1970: Double(i))
        }
        memory.replaceAll(incoming)
        #expect(memory.entries.count == SpoilerRevealMemory.maxEntries)
        #expect(!memory.isRevealed("u1|old"))
        #expect(memory.revealedKeys.count == memory.entries.count)
    }

    // MARK: Hiding again (Sodalite#222)

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test("hiding a reveal veils it again but keeps the reveal for older builds to union")
    func hideKeepsEntry() {
        let memory = SpoilerRevealMemory(store: defaults("hide"))
        memory.reveal("u1|i1", now: at(10))
        memory.hide("u1|i1", now: at(20))
        #expect(!memory.isRevealed("u1|i1"))
        #expect(memory.entries["u1|i1"] == at(10))
        #expect(memory.hiddenAt["u1|i1"] == at(20))
    }

    @Test("revealing again after a hide wins and drops the superseded hide")
    func revealAfterHide() {
        let memory = SpoilerRevealMemory(store: defaults("rereveal"))
        memory.reveal("u1|i1", now: at(10))
        memory.hide("u1|i1", now: at(20))
        memory.reveal("u1|i1", now: at(30))
        #expect(memory.isRevealed("u1|i1"))
        #expect(memory.hiddenAt["u1|i1"] == nil)
    }

    @Test("a hide is never stamped before the reveal it hides, whatever the clock says")
    func hideBeatsSkewedReveal() {
        let memory = SpoilerRevealMemory(store: defaults("skewHide"))
        memory.reveal("u1|i1", now: at(100))
        memory.hide("u1|i1", now: at(50))
        #expect(!memory.isRevealed("u1|i1"))
    }

    @Test("a reveal is never stamped before the hide it lifts, whatever the clock says")
    func revealBeatsSkewedHide() {
        let memory = SpoilerRevealMemory(store: defaults("skewReveal"))
        memory.reveal("u1|i1", now: at(10))
        memory.hide("u1|i1", now: at(100))
        memory.reveal("u1|i1", now: at(50))
        #expect(memory.isRevealed("u1|i1"))
    }

    @Test("hiding a key that was never revealed writes nothing")
    func hideUnrevealedIsNoOp() {
        let memory = SpoilerRevealMemory(store: defaults("noop"))
        memory.hide("u1|i1")
        #expect(memory.hiddenAt.isEmpty)
    }

    @Test("hideAll covers one profile and leaves the others alone")
    func hideAllIsPerUser() {
        let memory = SpoilerRevealMemory(store: defaults("hideAll"))
        memory.reveal("u1|a")
        memory.reveal("u1|b")
        memory.reveal("u2|a")
        memory.hideAll(userID: "u1")
        #expect(memory.revealedKeys == ["u2|a"])
    }

    @Test("hides survive a new instance over the same defaults")
    func hidePersists() {
        let store = defaults("hidePersist")
        let memory = SpoilerRevealMemory(store: store)
        memory.reveal("u1|i1", now: at(10))
        memory.hide("u1|i1", now: at(20))
        #expect(!SpoilerRevealMemory(store: store).isRevealed("u1|i1"))
    }

    @Test("a cloud apply without hides keeps the local ones")
    func replaceAllWithoutHidesKeepsLocal() {
        let memory = SpoilerRevealMemory(store: defaults("replaceHides"))
        memory.reveal("u1|i1", now: at(10))
        memory.hide("u1|i1", now: at(20))
        memory.replaceAll(["u1|i1": at(10)], hiddenAt: nil)
        #expect(!memory.isRevealed("u1|i1"))
    }
}
