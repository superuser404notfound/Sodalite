import Foundation
import Testing
@testable import Sodalite

/// Sodalite#119: the server list and the launch picker draw the remembered profiles of every known
/// server, while `JellyfinImageService` is built once around the ACTIVE client's providers. Avatars
/// on any other server were therefore requested from the active host under an id it does not know,
/// answered 404, and fell back to initials. These pin that the explicit variant addresses the server
/// it is handed and that the convenience one still follows the active session.
struct UserProfileImageURLTests {
    private func service(base: String?, token: String?) -> JellyfinImageService {
        JellyfinImageService(
            baseURLProvider: { base.flatMap(URL.init(string:)) },
            accessTokenProvider: { token }
        )
    }

    private func query(_ url: URL?, _ name: String) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    /// The whole defect in one assertion: an avatar on another server must not be requested from the
    /// active host.
    @Test func theExplicitVariantAddressesTheServerItIsHanded() {
        let url = service(base: "https://active.example", token: "activeToken")
            .userProfileImageURL(
                userID: "u1",
                tag: "t1",
                baseURL: URL(string: "https://other.example")!,
                token: "otherToken"
            )

        #expect(url?.host() == "other.example")
        #expect(url?.path() == "/Users/u1/Images/Primary")
        #expect(query(url, "api_key") == "otherToken")
        #expect(query(url, "ApiKey") == "otherToken")
    }

    /// `AsyncCachedImage` attaches `X-Emby-Token` only for the active host, so a foreign host is
    /// served by the token in the query or not at all. Carrying the ACTIVE token there would send it
    /// to a server it does not belong to.
    @Test func theExplicitVariantDoesNotCarryTheActiveToken() {
        let url = service(base: "https://active.example", token: "activeToken")
            .userProfileImageURL(
                userID: "u1",
                tag: "t1",
                baseURL: URL(string: "https://other.example")!,
                token: nil
            )

        #expect(url?.absoluteString.contains("activeToken") == false)
        #expect(query(url, "api_key") == nil)
    }

    /// No avatar on the server means no tag, and the UI wants nil so it can draw initials rather
    /// than a request that cannot succeed.
    @Test func aProfileWithoutAnAvatarResolvesToNothing() {
        let url = service(base: "https://active.example", token: "activeToken")
            .userProfileImageURL(
                userID: "u1",
                tag: nil,
                baseURL: URL(string: "https://other.example")!,
                token: "otherToken"
            )

        #expect(url == nil)
    }

    /// The active-session call sites (Settings header, the active-user badge, the login flow) keep
    /// following the client's own providers.
    @Test func theConvenienceVariantFollowsTheActiveSession() {
        let url = service(base: "https://active.example", token: "activeToken")
            .userProfileImageURL(userID: "u1", tag: "t1")

        #expect(url?.host() == "active.example")
        #expect(query(url, "api_key") == "activeToken")
    }

    /// Nothing to build against before a session exists.
    @Test func theConvenienceVariantIsNilWithoutABaseURL() {
        #expect(service(base: nil, token: "t").userProfileImageURL(userID: "u1", tag: "t1") == nil)
    }
}
