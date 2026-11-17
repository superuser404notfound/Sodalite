import Testing
import Foundation
@testable import Sodalite

/// Audit DET-201: the file is gone after a Seerr-stage failure (or after the first seasons of a
/// failed multi-season delete), so the page still has to clean up for what was deleted.
@MainActor
@Suite(.timeLimit(.minutes(1)))
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
            popDelay: .zero,
            pop: { recorder.popped += 1 },
            refreshAfterRemoval: { recorder.refreshed += 1 },
            delete: { if let error { throw error } }
        )
        return outcome
    }

    /// Lets a scheduled zero-delay pop run, so "no pop" can be asserted.
    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    @Test func successCleansUpAndPops() async {
        let r = Recorder()
        let outcome = await run(r)
        let popped = await DetailViewModelUserStateTests.waitFor { r.popped == 1 }
        #expect(popped)
        #expect(outcome == .success)
        #expect(r.evicted == ["srv"])
        #expect(r.posted == [.homeItemDidDelete, .seerrRequestsDidChange])
        #expect(r.popped == 1)
    }

    @Test func seerrStageFailureCleansUpAndReportsPartialButLeavesThePageToTheSheet() async {
        let r = Recorder()
        let outcome = await run(r, failing: MediaDeletionError(stage: .seerr, reason: .seerrNotSignedIn))
        if case .partialSuccess = outcome {} else { Issue.record("expected partialSuccess, got \(outcome)") }
        #expect(r.evicted == ["srv"])
        #expect(r.posted.contains(.homeItemDidDelete))
        await settle()
        #expect(r.popped == 0, "the page closes from the sheet's dismissal, not on a timer")
    }

    @Test func jellyfinStageFailureCleansNothing() async {
        let r = Recorder()
        let outcome = await run(r, failing: MediaDeletionError(stage: .jellyfin))
        if case .failure = outcome {} else { Issue.record("expected failure, got \(outcome)") }
        #expect(r.evicted.isEmpty)
        #expect(r.posted.isEmpty)
        await settle()
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
        await settle()
        #expect(r.popped == 0)
    }
}
