import Testing
@testable import Sodalite

@MainActor
struct MyRequestsPresentationTests {
    @Test func presentsOnlyWithEventsAndNothingElseOnScreen() {
        #expect(MyRequestsPresentationPolicy.shouldPresent(unseen: 1, authenticated: true, loading: false, modalActive: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 0, authenticated: true, loading: false, modalActive: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 2, authenticated: true, loading: false, modalActive: true))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 2, authenticated: false, loading: false, modalActive: false))
        #expect(!MyRequestsPresentationPolicy.shouldPresent(unseen: 2, authenticated: true, loading: true, modalActive: false))
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

    @Test func backgroundCloseKeepsEventsUnseen() {
        var flow = MyRequestsPanelFlow()
        #expect(flow.didEnterBackground(panelPresented: true) == .dismissPanel)
        #expect(flow.panelDidDismiss() == .init(markSeen: false, deepLink: nil))
        #expect(flow.didEnterBackground(panelPresented: false) == .none)
    }
}

