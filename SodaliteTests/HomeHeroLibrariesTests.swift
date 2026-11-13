import Foundation
import Testing
@testable import Sodalite

@Suite("Home banner libraries", .serialized)
@MainActor
struct HomeHeroLibrariesTests {
    private func library(_ id: String, _ type: String?, server: String? = "s1") -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: type, imageTags: nil, serverID: server)
    }

    @Test("only movie, show and mixed libraries can feed the banner")
    func eligibility() {
        let all = [
            library("m", "movies"), library("t", "tvshows"), library("x", "mixed"),
            library("b", "boxsets"), library("p", "playlists"), library("h", "homevideos"), library("u", "music"),
        ]
        #expect(HomeHeroLibraries.eligible(all).map(\.id) == ["m", "t", "x"])
    }

    @Test("a left-out library drops out, keyed by server and id")
    func included() {
        let all = [library("m", "movies"), library("t", "tvshows"), library("b", "boxsets")]
        let kept = HomeHeroLibraries.included(all, serverID: "s1", excluded: ["s1|m"])
        #expect(kept.map(\.id) == ["t"])
    }

    @Test("the same library id on another server stays in")
    func otherServer() {
        let kept = HomeHeroLibraries.included([library("m", "movies", server: "s2")], serverID: "s2", excluded: ["s1|m"])
        #expect(kept.map(\.id) == ["m"])
    }

    @Test("a library without a server id takes the source's, like originKey does")
    func unstampedLibrary() {
        let lib = library("m", "movies", server: nil)
        #expect(HomeHeroLibraries.included([lib], serverID: "s1", excluded: ["s1|m"]).isEmpty)
        var stamped = lib
        stamped.serverID = "s1"
        #expect(stamped.originKey == "s1|m")
    }

    @Test("a key names its server by prefix, not by substring")
    func keyOwnership() {
        #expect(HomeHeroLibraries.key("s1|m", belongsTo: "s1"))
        #expect(!HomeHeroLibraries.key("s10|m", belongsTo: "s1"))
    }

    @Test("no selection keeps the cache keys from before the selection existed")
    func signature() {
        #expect(HomeHeroLibraries.signature([]) == "")
        #expect(HomeHeroLibraries.signature(["s1|b", "s1|a"]) == "|s1|a,s1|b")
    }

    @Test("an emptied selection is stored, so sync can carry it to other devices")
    func emptiedSelectionSyncs() {
        let scope = "test-hero-libraries"
        HomeHeroLibraries.setExcluded(["s1|m"], scope: scope)
        HomeHeroLibraries.setExcluded([], scope: scope)
        #expect(HomeHeroLibraries.rawStored(scope: scope) == [])
        UserDefaults.standard.removeObject(forKey: "homeHeroExcludedLibraries.\(scope)")
        #expect(HomeHeroLibraries.rawStored(scope: scope) == nil)
    }
}
