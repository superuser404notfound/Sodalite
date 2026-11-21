import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 NETWORK-3 / NETWORK-4. URLSession replayed `X-Emby-Token` and Seerr's cookie to
/// whatever host a redirect named, https to http included, while it dropped `Authorization` even on
/// a same-host http to https upgrade.
@Suite("Which credentials a redirect may carry")
struct RedirectPolicyTests {

    private func request(_ url: String, credentials: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credentials {
            request.setValue("MediaBrowser Token=\"tok\"", forHTTPHeaderField: "Authorization")
            request.setValue("connect.sid=cookie", forHTTPHeaderField: "Cookie")
            request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        }
        return request
    }

    @Test("another host gets no credentials, and the other headers survive")
    func crossHostStrips() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://auth.example.com/login", credentials: true),
            from: request("https://seerr.example.com/api/v1/auth/me", credentials: true)))
        for name in RedirectPolicy.credentialHeaders {
            #expect(followed.value(forHTTPHeaderField: name) == nil)
        }
        #expect(followed.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("a port change within one scheme is another origin")
    func portChangeStrips() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("http://10.0.0.2:8097/x", credentials: true),
            from: request("http://10.0.0.2:8096/x", credentials: true)))
        #expect(followed.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }

    @Test("https to http is refused outright")
    func downgradeRefused() {
        #expect(RedirectPolicy.redirect(
            request("http://jf.example.com/x", credentials: true),
            from: request("https://jf.example.com/x", credentials: true)) == nil)
    }

    @Test("a same-host upgrade to https keeps the login, even where URLSession dropped it")
    func upgradeKeepsCredentials() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://jf.example.com/Users/AuthenticateByName", credentials: false),
            from: request("http://jf.example.com/Users/AuthenticateByName", credentials: true)))
        #expect(followed.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"tok\"")
        #expect(followed.value(forHTTPHeaderField: "X-Emby-Token") == "tok")
    }

    @Test("the same origin keeps what it had")
    func sameOriginKeeps() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://jf.example.com/web/index.html", credentials: true),
            from: request("https://jf.example.com/web", credentials: true)))
        #expect(followed.value(forHTTPHeaderField: "Cookie") == "connect.sid=cookie")
    }

    // MARK: Audit 2026-11-17 NET-209

    @Test("a token in the URL does not follow a forward-auth hop to another host")
    func tokenizedURLRefusedCrossHost() {
        #expect(RedirectPolicy.redirect(
            request("https://auth.example.com/?rd=https%3A%2F%2Fjf.example.com%2FItems%2Fx%2FImages%2FPrimary%3Fapi_key%3Dtok", credentials: false),
            from: request("https://jf.example.com/Items/x/Images/Primary?api_key=tok&ApiKey=tok", credentials: false)) == nil)
    }

    @Test("a tokenized URL still takes the same-host upgrade, and an untokenized one still crosses")
    func tokenizedURLKeepsTheAllowedHops() {
        #expect(RedirectPolicy.redirect(
            request("https://jf.example.com/Items/x/Images/Primary?api_key=tok", credentials: false),
            from: request("http://jf.example.com/Items/x/Images/Primary?api_key=tok", credentials: false)) != nil)
        #expect(RedirectPolicy.redirect(
            request("https://cdn.example.com/poster.jpg", credentials: false),
            from: request("https://jf.example.com/Items/x/Images/Primary?tag=t", credentials: false)) != nil)
    }

    // MARK: Sodalite#249

    private let token = "0123456789abcdef0123456789abcdef"

    @Test("artwork that redirects to an image host is followed without the token")
    func imageHostRedirectFollowedWithoutToken() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://img.example.net/t/p/w500/poster.jpg", credentials: false),
            from: request("https://jf.example.com/Items/x/Images/Primary?tag=t&api_key=\(token)", credentials: false)))
        #expect(followed.url?.absoluteString == "https://img.example.net/t/p/w500/poster.jpg")
    }

    @Test("a target that echoes the token keeps everything but the token, byte for byte")
    func echoedTokenIsDropped() throws {
        let signed = "X-Amz-Credential=AKIA%2F20261121%2Fus-east-1&X-Amz-Signature=ab%2Bcd"
        let followed = try #require(RedirectPolicy.redirect(
            request("https://cdn.example.net/poster.jpg?ApiKey=\(token)&\(signed)&api_key=\(token)", credentials: false),
            from: request("https://jf.example.com/Items/x/Images/Primary?ApiKey=\(token)", credentials: false)))
        #expect(followed.url?.absoluteString == "https://cdn.example.net/poster.jpg?\(signed)")
        #expect(RedirectPolicy.dropsQueryCredential(
            request("https://cdn.example.net/poster.jpg?ApiKey=\(token)", credentials: false),
            from: request("https://jf.example.com/Items/x/Images/Primary?ApiKey=\(token)", credentials: false)))
    }

    @Test("the token under another name is dropped too, nested or in the path it is refused")
    func tokenElsewhereRefused() throws {
        let from = request("https://jf.example.com/Items/x/Images/Primary?api_key=\(token)", credentials: false)
        let renamed = try #require(RedirectPolicy.redirect(
            request("https://new.example.com/Items/x/Images/Primary?key=\(token)&tag=t", credentials: false),
            from: from))
        #expect(renamed.url?.absoluteString == "https://new.example.com/Items/x/Images/Primary?tag=t")
        #expect(RedirectPolicy.redirect(
            request("https://auth.example.com/login?rd=https%253A%252F%252Fjf.example.com%252F%253Fapi_key%253D\(token)", credentials: false),
            from: from) == nil)
        #expect(RedirectPolicy.redirect(
            request("https://auth.example.com/login/\(token)", credentials: false),
            from: from) == nil)
    }

    @Test("a hop on the same origin keeps the token in the URL")
    func sameOriginKeepsURLToken() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://jf.example.com/Items/x/Images/Primary?api_key=\(token)", credentials: false),
            from: request("http://jf.example.com/Items/x/Images/Primary?api_key=\(token)", credentials: false)))
        #expect(followed.url?.query()?.contains(token) == true)
        #expect(!RedirectPolicy.dropsQueryCredential(
            request("https://jf.example.com/Items/x/Images/Primary?api_key=\(token)", credentials: false),
            from: request("http://jf.example.com/Items/x/Images/Primary?api_key=\(token)", credentials: false)))
    }
}
