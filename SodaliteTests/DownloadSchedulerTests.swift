import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadSchedulerTests {
    private func m(_ id: String, _ route: DownloadRoute, _ state: DownloadState = .queued, at t: TimeInterval = 0) -> DownloadManifest {
        DownloadManifest(itemID: id, seriesID: nil, seasonID: nil, quality: route == .original ? .original : .mbps4,
                         route: route, mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil,
                         state: state, createdAt: Date(timeIntervalSince1970: t))
    }

    @Test func twoOriginalsAtOnceInQueueOrder() {
        let queued = [m("c", .original, at: 3), m("a", .original, at: 1), m("b", .original, at: 2)]
        #expect(DownloadScheduler.toStart(queued: queued, running: []) == ["a", "b"])
    }

    @Test func oneTranscodeAtATime() {
        let queued = [m("t1", .transcode, at: 1), m("t2", .transcode, at: 2), m("o", .original, at: 3)]
        #expect(DownloadScheduler.toStart(queued: queued, running: []) == ["t1", "o"])
        #expect(DownloadScheduler.toStart(queued: [m("t2", .transcode)], running: [m("t1", .transcode, .downloading)]) == [])
    }

    @Test func runningOriginalsFillTheirSlots() {
        let running = [m("x", .original, .downloading), m("y", .original, .downloading)]
        #expect(DownloadScheduler.toStart(queued: [m("a", .original), m("t", .transcode)], running: running) == ["t"])
    }

    @Test func tagRoundTrip() {
        let tag = DownloadTaskTag(serverID: "s", userID: "u", itemID: "i", fileExtension: "mkv")
        #expect(DownloadTaskTag(encoded: tag.encoded) == tag)
        #expect(DownloadTaskTag(encoded: "garbage") == nil)
    }
}
