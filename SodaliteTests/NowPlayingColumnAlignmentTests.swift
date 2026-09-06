import Testing
import Foundation

/// Sodalite#108: on the wide (tvOS / iPad) Now Playing screen the album art sat far below the title
/// block beside it.
///
/// The mechanism is not that the metadata column is shorter. It is the opposite: that column holds
/// the queue's ScrollView, which is greedy in the vertical axis, so it always fills the container's
/// height while the cover column keeps its natural height. A centered HStack therefore moves only
/// the cover column, and the drop is half the height difference (measured at 107pt on a 1080p tvOS
/// screen, and larger on iPad where the cover is smaller than the tvOS one).
///
/// What is pinned here is that pairing: as long as the queue scrolls, the columns are top-aligned.
/// Top padding on the metadata column would be the alternative, and it would be a magic number that
/// drifts with cover size, title length and Dynamic Type.
struct NowPlayingColumnAlignmentTests {

    @Test("The wide layout tops the cover column out level with the metadata column")
    func wideColumnsAreTopAligned() throws {
        let source = try sourceFile("Sodalite/Features/Music/NowPlayingView.swift")

        #expect(source.contains("HStack(alignment: .top, spacing: NowPlayingMetrics.wideSpacing)"))
        #expect(!source.contains("HStack(alignment: .center"))
    }

    @Test("The queue column is still the greedy one that made the alignment matter")
    func queueColumnStillScrolls() throws {
        let source = try sourceFile("Sodalite/Features/Music/NowPlayingView.swift")

        #expect(source.contains("ScrollView(.vertical, showsIndicators: false)"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
