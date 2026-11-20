import Testing
import Foundation
@testable import Sodalite

/// `KeychainService` answers repeat reads from memory, because every SecItem call is an IPC round
/// trip and `activeUserID` made three of them per view body. The cache must never show a value the
/// keychain no longer holds.
struct KeychainServiceCacheTests {

    private func makeService() -> KeychainService {
        KeychainService(service: "de.superuser404.Sodalite.tests.\(UUID().uuidString)")
    }

    @Test func aSaveIsReadBack() throws {
        let keychain = makeService()
        defer { try? keychain.deleteAll() }

        try keychain.save("one", for: "k")
        #expect(try keychain.loadString(for: "k") == "one")
        try keychain.save("two", for: "k")
        #expect(try keychain.loadString(for: "k") == "two")
    }

    @Test func aDeleteIsReadBackAsMissing() throws {
        let keychain = makeService()
        defer { try? keychain.deleteAll() }

        try keychain.save("one", for: "k")
        _ = try keychain.loadString(for: "k")
        try keychain.delete(for: "k")
        #expect(try keychain.loadString(for: "k") == nil)
    }

    /// The container and the certificate-pin store each build their own instance.
    @Test func twoInstancesOnOneServiceSeeEachOthersWrites() throws {
        let service = "de.superuser404.Sodalite.tests.\(UUID().uuidString)"
        let first = KeychainService(service: service)
        let second = KeychainService(service: service)
        defer { try? first.deleteAll() }

        #expect(try first.loadString(for: "k") == nil)
        try second.save("from second", for: "k")
        #expect(try first.loadString(for: "k") == "from second")

        try second.deleteAll()
        #expect(try first.loadString(for: "k") == nil)
    }
}
