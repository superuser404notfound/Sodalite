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

    /// The functions that decode image bytes or JSON for a MainActor caller.
    @Test func theDecodePathsAreConcurrent() throws {
        let expected = [
            ("Sodalite/Components/AsyncCachedImage.swift", "@concurrent nonisolated private static func fetchAndDecode("),
            ("Sodalite/Player/PlayerViewModel.swift", "@concurrent nonisolated private static func loadServerChapterImage("),
            ("Sodalite/Player/PlayerViewModel+NowPlaying.swift", "@concurrent nonisolated static func nowPlayingJPEG("),
            ("Sodalite/Player/TrickplayTileStore.swift", "@concurrent nonisolated private static func decode("),
            ("Sodalite/Services/Networking/HTTPClient.swift", "@concurrent nonisolated private static func decode<T: Decodable>("),
            ("Sodalite/Player/Subtitles/SRTParser.swift", "@concurrent nonisolated static func parse("),
        ]
        for (path, signature) in expected {
            #expect(try sourceFile(path).contains(signature), "\(path) lost @concurrent on its decode")
        }
    }

    /// Audit NET-204: the three response paths that used to decode on the main actor go through
    /// `HTTPClient.decode` now, and no `decoder.decode(` call is left in them.
    @Test func theClientsDecodeThroughHTTPClient() throws {
        for path in ["Sodalite/Services/Seerr/SeerrClient.swift",
                     "Sodalite/Services/Jellyfin/JellyfinClient.swift",
                     "Sodalite/Services/Jellyfin/JellyfinPlaybackService.swift"] {
            let source = try sourceFile(path)
            #expect(source.contains("HTTPClient.decodeValue(from:"), "\(path) does not use HTTPClient.decode")
            #expect(!source.contains("decoder.decode(") && !source.contains("JSONDecoder().decode("),
                    "\(path) decodes on the main actor")
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
