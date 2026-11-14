import Testing
import Foundation
@testable import Sodalite

/// Every Home card decoded its artwork on the main thread, and nobody noticed for months because the
/// code said otherwise: `nonisolated static ... async` reads like "off the actor", but with
/// approachable concurrency on (`project.yml`) it runs on the CALLER's actor. Scrolling Home stuttered
/// while the cards came in one after another (Sodalite#212).
struct ImageDecodeOffMainTests {

    nonisolated private static func plainNonisolated() async -> Bool { pthread_main_np() != 0 }
    @concurrent nonisolated private static func concurrent() async -> Bool { pthread_main_np() != 0 }

    /// The trap itself, pinned so it stays visible: from MainActor, plain `nonisolated async` stays on
    /// the main thread, and only `@concurrent` leaves it.
    @MainActor @Test func plainNonisolatedAsyncStaysOnTheCallersActor() async {
        #expect(await Self.plainNonisolated())
        #expect(await !Self.concurrent())
    }

    /// The functions that decode image bytes for a MainActor caller.
    @Test func theDecodePathsAreConcurrent() throws {
        let expected = [
            ("Sodalite/Components/AsyncCachedImage.swift", "@concurrent nonisolated private static func fetchAndDecode("),
            ("Sodalite/Player/PlayerViewModel.swift", "@concurrent nonisolated private static func loadServerChapterImage("),
            ("Sodalite/Player/PlayerViewModel.swift", "@concurrent nonisolated private static func fetchTrickplayCrop("),
        ]
        for (path, signature) in expected {
            #expect(try sourceFile(path).contains(signature), "\(path) lost @concurrent on its decode")
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
