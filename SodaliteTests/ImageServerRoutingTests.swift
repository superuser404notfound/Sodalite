import Foundation
import Testing
@testable import Sodalite

@MainActor
struct ImageServerRoutingTests {
    private let service = JellyfinImageService(endpoint: { serverID in
        switch serverID {
        case "b": (URL(string: "http://b.lan:8096")!, "tok-b")
        default: (URL(string: "http://a.lan:8096")!, "tok-a")
        }
    })

    private func item(serverID: String?) throws -> JellyfinItem {
        let sid = serverID.map { #","ServerId":"\#($0)""# } ?? ""
        let json = #"{"Id":"i1","Name":"n","Type":"Movie","ImageTags":{"Primary":"p"}\#(sid)}"#
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func posterGoesToTheItemsServer() throws {
        let url = try #require(service.posterURL(for: try item(serverID: "b")))
        #expect(url.host == "b.lan")
        #expect(url.query?.contains("api_key=tok-b") == true)
    }

    @Test func itemWithoutServerIdUsesTheActiveServer() throws {
        let url = try #require(service.posterURL(for: try item(serverID: nil)))
        #expect(url.host == "a.lan")
        #expect(url.query?.contains("api_key=tok-a") == true)
    }

    @Test func libraryArtworkFollowsTheLibrarysServer() throws {
        var library = JellyfinLibrary(id: "lib", name: "Movies", collectionType: "movies",
                                      imageTags: ImageTags(primary: "p", backdrop: nil, thumb: nil, logo: nil, banner: nil))
        library.serverID = "b"
        let url = try #require(service.libraryArtworkURL(for: library))
        #expect(url.host == "b.lan")
    }

    @Test func personImageTakesAnExplicitServer() throws {
        let url = try #require(service.personImageURL(personID: "p1", tag: "t", serverID: "b"))
        #expect(url.host == "b.lan")
    }

    @Test func itemIDImageTakesAnExplicitServer() throws {
        let url = try #require(service.imageURL(itemID: "i1", serverID: "b", imageType: .logo, tag: "l"))
        #expect(url.host == "b.lan")
    }

    @Test func legacyInitStillWorks() throws {
        let legacy = JellyfinImageService(baseURLProvider: { URL(string: "https://jf.test") })
        let url = try #require(legacy.posterURL(for: try item(serverID: "b")))
        #expect(url.host == "jf.test")
    }
}
