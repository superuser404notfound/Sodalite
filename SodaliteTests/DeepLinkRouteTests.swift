import Testing
import Foundation
@testable import Sodalite

/// `sodalite://item/{id}` (Top Shelf displayAction) opens the detail sheet;
/// `sodalite://play/{id}` (playAction, the Play button on the remote) opens it and starts.
@MainActor
struct DeepLinkRouteTests {

    /// A real Jellyfin item id: the shelf only ever emits GUIDs, so that is what the parser accepts.
    private static let itemID = "0f9b1c2d3e4f5061728394a5b6c7d8e9"

    @Test("an item link opens detail without playing")
    func itemLink() {
        let route = DeepLinkRoute.parse(URL(string: "sodalite://item/\(Self.itemID)")!)
        #expect(route == DeepLinkRoute(itemID: Self.itemID, autoPlay: false))
    }

    @Test("a play link asks for playback")
    func playLink() {
        let route = DeepLinkRoute.parse(URL(string: "sodalite://play/\(Self.itemID)")!)
        #expect(route == DeepLinkRoute(itemID: Self.itemID, autoPlay: true))
    }

    @Test("a dashed GUID is the same id")
    func dashedGUID() {
        let dashed = "0f9b1c2d-3e4f-5061-7283-94a5b6c7d8e9"
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item/\(dashed)")!)
                == DeepLinkRoute(itemID: dashed, autoPlay: false))
    }

    @Test("a foreign scheme is rejected")
    func foreignScheme() {
        #expect(DeepLinkRoute.parse(URL(string: "jellyfin://item/\(Self.itemID)")!) == nil)
    }

    @Test("an unknown host is rejected")
    func unknownHost() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://search/\(Self.itemID)")!) == nil)
    }

    @Test("a missing id is rejected")
    func missingID() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://play/")!) == nil)
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item")!) == nil)
    }

    @Test("trailing path components are ignored")
    func extraComponents() {
        let route = DeepLinkRoute.parse(URL(string: "sodalite://play/\(Self.itemID)/extra")!)
        #expect(route == DeepLinkRoute(itemID: Self.itemID, autoPlay: true))
    }

    /// `pathComponents` percent-DECODES, so an escaped traversal arrives as `../../System/Info` and
    /// would otherwise be interpolated into the request path, where the server resolves it into a
    /// different endpoint with the session token still attached.
    @Test("an escaped path traversal is not an id")
    func escapedTraversal() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item/%2E%2E%2F%2E%2E%2FSystem%2FInfo")!) == nil)
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://play/..%2F..%2FUsers%2FPublic")!) == nil)
    }

    @Test("anything that is not a GUID is rejected")
    func nonGUID() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item/abc123")!) == nil)
        // 31 digits, one short.
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item/0f9b1c2d3e4f5061728394a5b6c7d8e")!) == nil)
        // 33 digits, one over.
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item/0f9b1c2d3e4f5061728394a5b6c7d8e9a")!) == nil)
        // Right length, but `g` is not a hex digit.
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item/gf9b1c2d3e4f5061728394a5b6c7d8e9")!) == nil)
    }

    /// A combined shelf's item from another server names it (Sodalite#218).
    @Test("a server parameter rides along")
    func serverParameter() {
        let server = "aa11bb22cc33dd44ee55ff6600778899"
        let route = DeepLinkRoute.parse(URL(string: "sodalite://play/\(Self.itemID)?server=\(server)")!)
        #expect(route == DeepLinkRoute(itemID: Self.itemID, autoPlay: true, serverID: server))
    }

    /// The server id picks the session the request goes out on, so it is held to the item id's shape.
    @Test("a server that is not a GUID rejects the link")
    func badServerParameter() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://play/\(Self.itemID)?server=../x")!) == nil)
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://play/\(Self.itemID)?server=")!) == nil)
    }

    /// `Character.isHexDigit` says yes to the fullwidth forms; a GUID is ASCII.
    @Test("fullwidth digits are not hex digits")
    func fullwidthDigits() {
        #expect(DeepLinkRoute.isItemID("０f9b1c2d3e4f5061728394a5b6c7d8e9") == false)
    }
}
