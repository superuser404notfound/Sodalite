import Testing
@testable import Sodalite

/// Sodalite#234: every reload reparses the whole growing script, so events far ahead of the
/// playhead wait in the builder instead of costing a parse every 5 s.
struct ASSReloadPolicyTests {
    private func due(start: Double, playhead: Double = 100, since: Double) -> Bool {
        ASSRenderCoordinator.reloadIsDue(earliestPendingStart: start, playhead: playhead,
                                         sinceLastReload: since, imminentLead: 10, reloadLead: 30,
                                         imminentSpacing: 0.25, batchSpacing: 5)
    }

    @Test("an imminent event reloads after the short spacing")
    func imminent() {
        #expect(due(start: 105, since: 0.3))
        #expect(!due(start: 105, since: 0.1))
        #expect(due(start: 90, since: 0.3))
    }

    @Test("an event inside the lead reloads on the batch spacing")
    func insideLead() {
        #expect(due(start: 125, since: 5))
        #expect(!due(start: 125, since: 4))
    }

    @Test("an event beyond the lead waits, however long ago the last reload was")
    func beyondLead() {
        #expect(!due(start: 190, since: 600))
        #expect(!due(start: .infinity, since: 600))
    }
}
