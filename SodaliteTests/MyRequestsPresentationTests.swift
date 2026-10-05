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
}
