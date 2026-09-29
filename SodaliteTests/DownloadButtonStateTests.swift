import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadButtonStateTests {
    private func item(_ state: DownloadState) -> DownloadedItem {
        let json = #"{"Id":"a","Name":"x","Type":"Movie"}"#
        let src = try! JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"s"}"#.utf8))
        var m = DownloadManifest(itemID: "a", seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                 mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: Date())
        switch state {
        case .queued: break
        case .downloading: m.transition(to: .downloading)
        case .paused: m.transition(to: .paused)
        case .failed: m.transition(to: .failed)
        case .complete: m.transition(to: .downloading); m.transition(to: .complete)
        case .missingOnServer: m.transition(to: .downloading); m.transition(to: .complete); m.transition(to: .missingOnServer)
        }
        return DownloadedItem(manifest: m, snapshot: DownloadSnapshot(item: try! JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8)), series: nil, season: nil, source: src), directory: URL(fileURLWithPath: "/x"))
    }

    /// Vincent, device round 2026-09-29: the finished download wore the watched checkmark.
    @Test func aFinishedDownloadDoesNotLookWatched() {
        #expect(!DownloadButtonState.downloaded.systemImage.contains("checkmark"))
    }

    @Test func states() {
        #expect(DownloadButtonState.from(nil, liveProgress: nil) == .available)
        #expect(DownloadButtonState.from(item(.queued), liveProgress: nil) == .queued)
        #expect(DownloadButtonState.from(item(.downloading), liveProgress: 0.4) == .downloading(0.4))
        #expect(DownloadButtonState.from(item(.paused), liveProgress: nil) == .paused)
        #expect(DownloadButtonState.from(item(.failed), liveProgress: nil) == .failed)
        #expect(DownloadButtonState.from(item(.complete), liveProgress: nil) == .downloaded)
        #expect(DownloadButtonState.from(item(.missingOnServer), liveProgress: nil) == .downloaded)
    }
}

