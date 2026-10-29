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
