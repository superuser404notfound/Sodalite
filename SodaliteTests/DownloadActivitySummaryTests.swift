import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadActivitySummaryTests {
    private func d(_ id: String, _ state: DownloadState, expected: Int64?, received: Int64 = 0) -> DownloadedItem {
        let item = try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"x","Type":"Movie"}"#.utf8))
        let src = try! JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"s"}"#.utf8))
        var m = DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                 mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: Date())
        m.expectedBytes = expected
        m.receivedBytes = received
        switch state {
        case .queued: break
        case .downloading: m.transition(to: .downloading)
        case .complete: m.complete()
        case .failed: m.transition(to: .failed)
        case .paused: m.transition(to: .paused)
        case .missingOnServer: m.complete(); m.transition(to: .missingOnServer)
        }
        return DownloadedItem(manifest: m, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src),
                              directory: URL(fileURLWithPath: "/x"))
    }

    @Test func countsTheBatchAndItsBytes() {
        let items = [d("a", .complete, expected: 1000, received: 1000),
                     d("b", .downloading, expected: 1000),
                     d("c", .queued, expected: 2000),
                     d("other", .downloading, expected: 9999)]
        let summary = DownloadActivitySummary.make(batch: ["a", "b", "c"], items: items, liveProgress: ["b": 0.5])
        #expect(summary == DownloadActivitySummary(finished: 1, pending: 2, total: 3, receivedBytes: 1500, totalBytes: 4000))
        #expect(summary?.isDone == false)
    }

    @Test func aFailedOrRemovedItemNoLongerHoldsTheActivityOpen() {
        let items = [d("a", .complete, expected: 1000, received: 1000), d("b", .failed, expected: 1000)]
        let summary = DownloadActivitySummary.make(batch: ["a", "b", "gone"], items: items, liveProgress: [:])
        #expect(summary?.isDone == true)
        #expect(summary?.total == 2)
    }

    @Test func nothingLeftIsNoSummary() {
        #expect(DownloadActivitySummary.make(batch: ["gone"], items: [], liveProgress: [:]) == nil)
    }
}
