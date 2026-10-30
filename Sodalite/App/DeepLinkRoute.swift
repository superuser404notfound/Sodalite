import Foundation

/// The `sodalite://` links the Top Shelf emits. `item` is the cell's displayAction (Select),
/// `play` its playAction (the remote's Play button). `?server=` names the server of a combined
/// shelf's item that is not on the active one (Sodalite#218).
struct DeepLinkRoute: Equatable {
    let itemID: String
    let autoPlay: Bool
    var serverID: String? = nil

    static func parse(_ url: URL) -> DeepLinkRoute? {
        guard url.scheme == "sodalite" else { return nil }
        let autoPlay: Bool
        switch url.host {
        case "item": autoPlay = false
        case "play": autoPlay = true
        default: return nil
        }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard isItemID(id) else { return nil }
        let server = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "server" }?.value
        // A server id is the same 32-digit GUID shape, and is checked as strictly: it picks the
        // session the request goes out on.
        if let server, !isItemID(server) { return nil }
        return DeepLinkRoute(itemID: id, autoPlay: autoPlay, serverID: server)
    }

    /// A Jellyfin item id is a GUID: 32 hex digits, dashed or not. Checked here rather than left to
    /// the fetch, because the id is interpolated into a request path and `pathComponents` hands back
    /// a percent-DECODED component: `sodalite://item/%2E%2E%2F%2E%2E%2FSystem%2FInfo` arrives as
    /// `../../System/Info` and survives unescaped into `URLRequest.url`, where the server resolves it
    /// into a different endpoint carrying the session token. The Top Shelf is the only producer of
    /// these links and only ever emits a GUID, so anything else is not one of ours.
    static func isItemID(_ id: String) -> Bool {
        var digits = 0
        for character in id.unicodeScalars {
            if character == "-" { continue }
            guard hexDigits.contains(character) else { return false }
            digits += 1
        }
        return digits == 32
    }

    /// ASCII only, deliberately: `Character.isHexDigit` also accepts fullwidth and other Unicode
    /// forms, which are not what a GUID is made of.
    private static let hexDigits = Set("0123456789abcdefABCDEF".unicodeScalars)
}

/// What the deep-link cover presents: the fetched item together with whether it should start
/// playing. One value rather than two parallel `@State`s, so the cover can never be built from the
/// new item while still reading the previous flag.
struct DeepLinkPresentation: Identifiable {
    let item: JellyfinItem
    let autoPlay: Bool

    /// Includes autoPlay so re-opening the same item with a different intent counts as a new presentation.
    var id: String { "\(item.id)-\(autoPlay)" }
}
