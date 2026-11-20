import Testing
@testable import Sodalite

/// Sodalite#140. The TabView used to answer Menu for us. A hand-built shell has to, and the chain
/// is the tvOS convention: out of the content, then to the landing tab, then out of the app. Get
/// this wrong and the very first Menu press quits Sodalite.
struct SidebarExitPolicyTests {

    @Test("Menu in the content goes to the rail rather than out of the app")
    func fromContent() {
        for tab in AppTab.allCases {
            #expect(SidebarExitPolicy.next(focusIsInRail: false, selectedTab: .app(tab)) == .focusRail)
        }
    }

    @Test("Menu in the rail goes to Home first")
    func fromRail() {
        #expect(SidebarExitPolicy.next(focusIsInRail: true, selectedTab: .settings) == .selectHome)
        #expect(SidebarExitPolicy.next(focusIsInRail: true, selectedTab: .music) == .selectHome)
        let pinned = PinnedLibraryTab(library: JellyfinLibrary(id: "m", name: "Movies", collectionType: "movies", imageTags: nil))
        #expect(SidebarExitPolicy.next(focusIsInRail: true, selectedTab: .library(pinned)) == .selectHome)
    }

    @Test("Menu in the rail on Home is the only way out of the app")
    func fromRailOnHome() {
        #expect(SidebarExitPolicy.next(focusIsInRail: true, selectedTab: .home) == .leaveApp)
    }
}
