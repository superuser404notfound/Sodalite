import Testing
import Foundation
@testable import Sodalite

/// Audit DET-201: the file is gone after a Seerr-stage failure (or after the first seasons of a
/// failed multi-season delete), so the page still has to clean up for what was deleted.
@MainActor
struct DetailDeletionCleanupTests {
    private struct Boom: Error {}

    private final class Recorder {
        var evicted: [String] = []
        var posted: [Notification.Name] = []
        var popped = 0
        var refreshed = 0
    }

    private func run(
        _ recorder: Recorder,
        cascaded: Bool = true,
        pops: Bool = true,
        partialRemoval: Bool = false,
        failing error: Error? = nil
    ) async -> DetailDeletion.Outcome {
        let outcome = await DetailDeletion.run(
            serverID: "srv",
            cascadedToArrStack: cascaded,
            popsWhenRemoved: pops,
            assumesPartialRemoval: partialRemoval,
            evictFilterCache: { recorder.evicted.append($0) },
            post: { recorder.posted.append($0) },
            pop: { recorder.popped += 1 },
            refreshAfterRemoval: { recorder.refreshed += 1 },
            delete: { if let error { throw error } }
        )
        // The pop sits behind the toast hold.
        try? await Task.sleep(for: .milliseconds(1300))
        return outcome
    }

    @Test func successCleansUpAndPops() async {
        let r = Recorder()
        let outcome = await run(r)
        #expect(outcome == .success)
        #expect(r.evicted == ["srv"])
        #expect(r.posted == [.homeItemDidDelete, .seerrRequestsDidChange])
        #expect(r.popped == 1)
    }

    @Test func seerrStageFailureStillCleansUpAndPopsButReportsPartial() async {
        let r = Recorder()
        let outcome = await run(r, failing: MediaDeletionError(stage: .seerr, reason: .seerrNotSignedIn))
        if case .partialSuccess = outcome {} else { Issue.record("expected partialSuccess, got \(outcome)") }
        #expect(r.evicted == ["srv"])
        #expect(r.posted.contains(.homeItemDidDelete))
        #expect(r.popped == 1)
    }

    @Test func jellyfinStageFailureCleansNothing() async {
        let r = Recorder()
        let outcome = await run(r, failing: MediaDeletionError(stage: .jellyfin))
        if case .failure = outcome {} else { Issue.record("expected failure, got \(outcome)") }
        #expect(r.evicted.isEmpty)
        #expect(r.posted.isEmpty)
        #expect(r.popped == 0)
    }

    @Test func seasonDeleteFailingMidwayRefreshesInsteadOfPopping() async {
        let r = Recorder()
        let outcome = await run(r, cascaded: false, pops: false, partialRemoval: true,
                                failing: MediaDeletionError(stage: .jellyfin))
        if case .failure = outcome {} else { Issue.record("expected failure, got \(outcome)") }
        #expect(r.evicted == ["srv"])
        #expect(r.posted == [.homeItemDidDelete])
        #expect(r.refreshed == 1)
        #expect(r.popped == 0)
    }
}
