import Testing
@testable import Sodalite

@MainActor
struct MyRequestsPresentationTests {
    @Test func presentsOnlyWithEventsAndNothingElseOnScreen() {
        #expect(MyRequestsPresentationPolicy.shouldPresent(unseen: 1, authenticated: true, loading: false, modalActive: false, profileLocked: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 0, authenticated: true, loading: false, modalActive: false, profileLocked: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 2, authenticated: true, loading: false, modalActive: true, profileLocked: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 2, authenticated: false, loading: false, modalActive: false, profileLocked: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 2, authenticated: true, loading: true, modalActive: false, profileLocked: false))
    }

    /// Sodalite TestFlight feedback 2026-10-22: the panel landed ahead of the profile reprompt and
    /// let its viewer into a PIN-locked profile.
    @Test func waitsForTheProfileToBeLetIn() {
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 1, authenticated: true, loading: false, modalActive: false, profileLocked: true))
    }

    @Test func watchDefersTheDeepLinkUntilThePanelIsGone() {
        var flow = MyRequestsPanelFlow()
        #expect(flow.watch("item") == .dismissPanel)
        #expect(flow.panelDidDismiss() == .init(markSeen: true, deepLink: "item"))
        #expect(flow.panelDidDismiss() == .init(markSeen: true, deepLink: nil))
    }

    @Test func bannerTapClosesAnOpenPanelBeforeNavigating() {
        var flow = MyRequestsPanelFlow()
        #expect(flow.bannerOpened("item", panelPresented: true) == .dismissPanel)
        #expect(flow.panelDidDismiss().deepLink == "item")
        #expect(flow.bannerOpened("other", panelPresented: false) == .navigate("other"))
    }

    @Test func closingForBackgroundOrProfileLockKeepsEventsUnseen() {
        var flow = MyRequestsPanelFlow()
        #expect(flow.closeUnread(panelPresented: true) == .dismissPanel)
        #expect(flow.panelDidDismiss() == .init(markSeen: false, deepLink: nil))
        #expect(flow.closeUnread(panelPresented: false) == .none)
    }
}


@MainActor
struct MyRequestsBackgroundPolicyTests {
    @Test func keepsSchedulingUnlessTheProfileSwitchedItOff() {
        #expect(MyRequestsBackgroundRefresh.keepScheduling(scope: nil, notifyEnabled: { _ in false }))
        #expect(MyRequestsBackgroundRefresh.keepScheduling(scope: "s_a", notifyEnabled: { _ in true }))
        #expect(!MyRequestsBackgroundRefresh.keepScheduling(scope: "s_a", notifyEnabled: { _ in false }))
    }
}

#if !os(macOS)
@MainActor
struct BackgroundRefreshWaitTests {
    /// PTD-204: a cold background launch has no Seerr session yet, so the handler waits for it.
    @Test func waitsUntilTheConditionTurnsTrue() async {
        var ready = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            ready = true
        }
        #expect(await BackgroundRefreshTask.waitFor(timeout: .seconds(3)) { ready })
    }

    @Test func givesUpAtTheDeadline() async {
        #expect(!(await BackgroundRefreshTask.waitFor(timeout: .milliseconds(600)) { false }))
    }
}
#endif
