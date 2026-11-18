import Foundation
import Testing

@testable import Sodalite

/// A self-hosted server behind its own certificate is refused by URLSession before a byte is read,
/// and the only way past that which is not "trust everything" is to remember the one certificate the
/// user looked at and accepted. What is remembered is a fingerprint per host, so the LAN address of a
/// dual-URL server can be trusted without the WAN address inheriting it.
@Suite("Server certificate trust store")
struct ServerTrustStoreTests {

    private nonisolated final class FakePinStorage: TrustPinStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var pins: [String: String]
        private(set) var saveCount = 0

        init(_ pins: [String: String] = [:]) { self.pins = pins }

        nonisolated func loadPins() -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            return pins
        }

        nonisolated func savePins(_ pins: [String: String]) {
            lock.lock(); self.pins = pins; saveCount += 1; lock.unlock()
        }
    }

    @Test("A host nobody trusted has no pin")
    func unknownHostHasNoPin() {
        let store = ServerTrustStore(storage: FakePinStorage())
        #expect(store.pinnedFingerprint(forHost: "media.lan:8920") == nil)
    }

    @Test("A pin answers for its own host and for no other")
    func pinIsPerHost() {
        let store = ServerTrustStore(storage: FakePinStorage())
        store.pin("a419", forHost: "media.lan:8920")

        #expect(store.pinnedFingerprint(forHost: "media.lan:8920") == "a419")
        // The WAN half of a dual-URL server is a different host and must not inherit the decision.
        #expect(store.pinnedFingerprint(forHost: "media.example.com:443") == nil)
    }

    @Test("A pin outlives the store that wrote it")
    func pinRoundTripsThroughStorage() {
        let storage = FakePinStorage()
        ServerTrustStore(storage: storage).pin("a419", forHost: "media.lan:8920")

        #expect(storage.saveCount == 1, "the pin was kept in memory only")
        let reopened = ServerTrustStore(storage: storage)
        #expect(reopened.pinnedFingerprint(forHost: "media.lan:8920") == "a419")
    }

    /// Audit 2026-11-17 NET-205: the reset wiped the keychain item, but the pins in memory kept
    /// the old certificates accepted, and the next accepted one wrote them all back.
    @Test("A factory reset takes the pins out of memory too")
    func resetForgetsEveryPin() {
        let storage = FakePinStorage(["old.lan:8920": "dead"])
        let store = ServerTrustStore(storage: storage)

        store.removeAll()
        store.pin("beef", forHost: "new.lan:8920")

        #expect(store.pinnedFingerprint(forHost: "old.lan:8920") == nil)
        #expect(storage.loadPins() == ["new.lan:8920": "beef"])
    }

    @Test("One address is one host however it was typed")
    func hostKeyNormalises() {
        // The port is part of the key, because a second Jellyfin on the same box behind a different
        // certificate is an ordinary setup. It has to come from the scheme when the URL omits it, or
        // the address bar and the challenge would disagree about the same server.
        #expect(ServerTrustStore.hostKey(for: URL(string: "https://Media.LAN:8920/")!) == "media.lan:8920")
        #expect(ServerTrustStore.hostKey(for: URL(string: "https://media.lan/")!) == "media.lan:443")
        #expect(ServerTrustStore.hostKey(for: URL(string: "https://media.lan:443/x")!) == "media.lan:443")
        #expect(ServerTrustStore.hostKey(for: URL(string: "http://media.lan/")!) == "media.lan:80")
        #expect(ServerTrustStore.hostKey(for: URL(string: "file:///tmp/x")!) == nil)
    }

    @Test("A refusal is remembered so it can be shown, and is not a pin")
    func refusalIsRememberedSeparately() {
        let store = ServerTrustStore(storage: FakePinStorage())
        store.noteRefused("a419", forHost: "media.lan:8920")

        #expect(store.refusedFingerprint(forHost: "media.lan:8920") == "a419")
        #expect(store.pinnedFingerprint(forHost: "media.lan:8920") == nil,
                "seeing a certificate is not accepting it")
    }

    @Test("A refusal is not written to storage")
    func refusalIsNotPersisted() {
        // What the user has not decided about must not survive the launch. Persisting it would make
        // a certificate the app merely saw look, on the next read, like a certificate it was told about.
        let storage = FakePinStorage()
        let store = ServerTrustStore(storage: storage)
        store.noteRefused("a419", forHost: "media.lan:8920")

        #expect(storage.saveCount == 0)
        #expect(ServerTrustStore(storage: storage).refusedFingerprint(forHost: "media.lan:8920") == nil)
    }

    @Test("A fingerprint is shown in pairs, because that is how it gets compared")
    func groupedFingerprintIsReadable() {
        #expect(CertificateFingerprint.grouped("a4196cf2") == "A4:19:6C:F2")
        #expect(CertificateFingerprint.grouped("") == "")
    }
}
