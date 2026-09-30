import Foundation
import Testing
@testable import Sodalite

/// The diagnostic log is meant to be handed to someone else, so a credential that survives into it is
/// published the moment a reporter screenshots it. These pin the shapes that actually occur in Sodalite's
/// own lines and in AetherEngine's, not a generic notion of "looks secret".
@Suite("Diagnostic log credential stripping")
struct LogRedactionTests {

    private let token = "9f2c1ab34de5470fa1b6c8d90e7f2a11"

    @Test("the Jellyfin stream URL loses its api_key and keeps everything else")
    func streamURLQuery() {
        let line = LogRedaction.redact(
            "[AetherEngine] load url=https://media.example.org/Videos/abc123/stream.mkv" +
            "?api_key=\(token)&Static=true&MediaSourceId=abc123 source-format=mkv"
        )
        #expect(!line.contains(token))
        #expect(line.contains("api_key=<redacted>"))
        // The parts a playback bug is actually diagnosed from must survive.
        #expect(line.contains("media.example.org/Videos/abc123/stream.mkv"))
        #expect(line.contains("Static=true"))
        #expect(line.contains("MediaSourceId=abc123"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    /// JellyfinImageService threads the token through BOTH spellings for server-version coverage, so
    /// stripping only the classic one would still ship the credential.
    @Test("both api_key and ApiKey spellings are stripped")
    func bothImageTokenSpellings() {
        let line = LogRedaction.redact(
            "[Image] fetch failed https://s/Items/1/Images/Primary?api_key=\(token)&ApiKey=\(token): timeout"
        )
        #expect(!line.contains(token))
        #expect(line.contains("api_key=<redacted>"))
        #expect(line.contains("ApiKey=<redacted>"))
        #expect(line.hasSuffix(": timeout"))
    }

    @Test("the MediaBrowser header form is stripped inside its quotes")
    func headerForm() {
        let line = LogRedaction.redact(#"Authorization: MediaBrowser Client="Sodalite", Token="\#(token)", Device="Apple TV""#)
        #expect(!line.contains(token))
        #expect(line.contains(#"Token="<redacted>""#))
        #expect(line.contains(#"Client="Sodalite""#))
        #expect(line.contains(#"Device="Apple TV""#))
    }

    @Test("the Seerr session cookie is stripped up to the attribute separator")
    func cookieForm() {
        let line = LogRedaction.redact("[Seerr] connect.sid=s%3Aabc.def+ghi; Path=/; HttpOnly")
        #expect(!line.contains("s%3Aabc.def"))
        #expect(line.contains("connect.sid=<redacted>"))
        #expect(line.hasSuffix("; Path=/; HttpOnly"))
    }

    @Test("X-Emby-Token and X-MediaBrowser-Token are stripped once, not twice")
    func headerNameVariants() {
        let line = LogRedaction.redact("X-Emby-Token=\(token) X-MediaBrowser-Token=\(token)")
        #expect(line == "X-Emby-Token=<redacted> X-MediaBrowser-Token=<redacted>")
    }

    /// A header separator spaces its value out; an `=` never does. Both have to work, and the second
    /// rule is what keeps "api_key= (missing)" from reading as a credential.
    @Test("the colon-separated header form is stripped")
    func colonSeparatedHeader() {
        let line = LogRedaction.redact("[http] X-Emby-Token: \(token) sent")
        #expect(!line.contains(token))
        #expect(line == "[http] X-Emby-Token: <redacted> sent")
    }

    /// The broad `token` key must not fire mid-identifier, or ordinary diagnostics start reading as
    /// redactions and the log loses the counters it exists for.
    @Test("a token substring inside another identifier is left alone")
    func doesNotFireMidIdentifier() {
        for line in [
            "[session] hasToken=true refreshTokenAt=120s",
            "[SWDiag] enq=48 layerDrop=0 delay=0.02 cushion=1.8",
            "[LiveDirect] eligible: route=hls tuner=file",
        ] {
            #expect(LogRedaction.redact(line) == line)
        }
    }

    @Test("an empty value and a bare mention are left alone")
    func nothingToStrip() {
        #expect(LogRedaction.redact("[auth] api_key= (missing)") == "[auth] api_key= (missing)")
        #expect(LogRedaction.redact("no token was supplied") == "no token was supplied")
    }

    @Test("several credentials in one line are all stripped")
    func multiplePerLine() {
        let line = LogRedaction.redact("a=1&api_key=\(token)&b=2&token=\(token)&c=3")
        #expect(!line.contains(token))
        #expect(line == "a=1&api_key=<redacted>&b=2&token=<redacted>&c=3")
    }

    /// The loopback URLs the engine serves on carry no credential; they are the most common URL in the
    /// log and must come through untouched.
    @Test("a loopback serving URL is untouched")
    func loopbackURL() {
        let line = "[HLSVideoEngine] serving on http://127.0.0.1:52341/master.m3u8 (dvModeAvailable=true)"
        #expect(LogRedaction.redact(line) == line)
    }

    // MARK: - Credentials carried in the URL authority

    /// A credential does not always arrive as `key=value`. An `smb://` or `http://` URL puts it in the
    /// authority, where the key matcher has nothing to match on, so it used to pass through whole.
    @Test("a password in the URL authority is stripped, the user name survives")
    func urlUserInfoPassword() {
        let line = LogRedaction.redact(
            "[AetherEngine] load url=smb://vincent:\(token)@nas.local/media/film.mkv source-format=mkv")
        #expect(!line.contains(token))
        #expect(line.contains("smb://vincent:<redacted>@nas.local/media/film.mkv"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    @Test("a bare token in the authority has no user name to spare, so all of it goes")
    func urlUserInfoWithoutUserName() {
        let line = LogRedaction.redact("[SMBIOReader] open smb://\(token)@nas.local/share")
        #expect(!line.contains(token))
        #expect(line.contains("smb://<redacted>@nas.local/share"))
    }

    /// Reported privately against the engine, and it applies here for the same reason the userinfo
    /// shape does: the host composes lines the engine never sees, so a gap closed only upstream is
    /// still open on this side. A credential encoded into a path segment has no name in the line at
    /// all, and no list of names can reach it, because the names are inside the payload.
    @Test("a credential encoded into a path segment goes, although nothing in the line names it")
    func encodedPathSegment() {
        // {"stores":[{"c":"tb","t":"9f2c1ab34de5470fa1b6c8d90e7f2a11abcd"}]}
        let segment = "eyJzdG9yZXMiOlt7ImMiOiJ0YiIsInQiOiI5ZjJjMWFiMzRkZTU0NzBmYTFiNmM4ZDkwZTdmMmExMWFiY2QifV19"
        let line = LogRedaction.redact(
            "[Image] fetch failed https://proxy.example.org/stremio/torz/\(segment)/_/strem/tt0111161/0/A.mkv"
        )
        #expect(!line.contains(segment))
        #expect(line.contains("/stremio/torz/<redacted>/_/strem/"))
        #expect(line.contains("proxy.example.org"))
        #expect(line.hasSuffix("A.mkv"))
    }

    /// The gate is the encoding, not a resemblance to it: an item id, a hash and an episode file that
    /// happens to start with the same two letters are exactly what a report is diagnosed from.
    @Test("an ordinary path segment that merely looks encoded is left alone", arguments: [
        "[AetherEngine] load url=https://s/Videos/Eyewitness.S01E04.mkv source-format=mkv",
        "[session] resume item=a1b2c3d4e5f60718293a4b5c6d7e8f90 position=421.5s",
    ])
    func ordinarySegmentsSurvive(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("a URL without credentials is untouched")
    func urlWithoutUserInfoIsUntouched() {
        let plain = "[AetherEngine] load url=https://media.example.org/Videos/abc/stream.mkv"
        #expect(LogRedaction.redact(plain) == plain)
    }

    /// The scan must not treat any later `@` on the line as an authority, or it would swallow the
    /// text between them and take the diagnosis with it.
    @Test("prose after a plain URL is not mistaken for an authority")
    func atSignInProseIsNotAnAuthority() {
        let prose = "[diag] tried https://a.test and then asked someone@example.org about it"
        #expect(LogRedaction.redact(prose) == prose)
    }

    @Test("both shapes on one line are each stripped")
    func userInfoAndQueryKeyTogether() {
        let line = LogRedaction.redact(
            "[test] url=http://user:\(token)@host/x?api_key=\(token)&Static=true")
        #expect(!line.contains(token))
        #expect(line.contains("http://user:<redacted>@host/x"))
        #expect(line.contains("api_key=<redacted>"))
        #expect(line.hasSuffix("Static=true"))
    }

    @Test("redaction runs on the way into the buffer, not only in the view")
    @MainActor
    func tapRedactsOnIngest() async {
        LogTap.shared.clear()
        LogTap.shared.note("[test] url=https://s/x?api_key=\(token)")
        // note(_:) hops to the main queue; let that drain.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(LogTap.shared.lines.contains { $0.contains("api_key=<redacted>") })
        #expect(!LogTap.shared.lines.contains { $0.contains(token) })
        LogTap.shared.clear()
    }

    @Test("an Xtream Codes path loses its password and keeps the account name", arguments: [
        ("http://h:8080/live/john/S3cretPass/12345.m3u8", "http://h:8080/live/john/<redacted>/12345.m3u8"),
        ("http://h:8080/timeshift/john/S3cretPass/60/2026-09-24:20-00/12345.ts",
         "http://h:8080/timeshift/john/<redacted>/60/2026-09-24:20-00/12345.ts"),
        ("http://h:8080/hlsr/a1b2c3d4e5/john/S3cretPass/12345/1/7.ts", "http://h:8080/hlsr/<redacted>/12345/1/7.ts"),
    ])
    func xtreamPath(url: String, expected: String) {
        #expect(LogRedaction.redact("[x] load url=\(url) ok") == "[x] load url=\(expected) ok")
    }

    @Test("an ordinary path under the same prefixes is left alone", arguments: [
        "https://origin.example/live/master.m3u8",
        "https://origin.example/live/channel1/index.m3u8",
        "https://jellyfin.example/LiveTv/LiveStreamFiles/abc/stream.ts",
    ])
    func ordinaryPrefixedPathsSurvive(url: String) {
        #expect(LogRedaction.redact("[x] url=\(url) ok") == "[x] url=\(url) ok")
    }
}

/// Audit 2026-09-25 DIAG-1 / DIAG-3: shapes the pre-7.17.0 copy let through. Each one was measured
/// leaking a secret through both redaction passes, the engine's and this one.
@Suite("Diagnostic log credential stripping, hostile shapes")
struct LogRedactionHostileShapeTests {

    private let secret = "SECRETabc123def"

    @Test("an origin URL percent-encoded into a relay query loses its token and keeps the rest")
    func percentEncodedRelayOrigin() {
        let line = LogRedaction.redact(
            "[HLSLocalServer] GET /deadbeef/aether-origin-relay?origin=https%3A%2F%2Fjf%2Eexample%2Ecom" +
            "%3A8920%2FVideos%2Fabc%2Fmaster%2Em3u8%3FMediaSourceId%3Dx%26api%5Fkey%3D\(secret)%26Tag%3D7 HTTP/1.1 fd=12")
        #expect(!line.contains(secret))
        #expect(line.contains("%26Tag%3D7 HTTP/1.1 fd=12"))
        #expect(line.contains("jf%2Eexample%2Ecom"))
    }

    @Test("a key or separator under one or two encoding layers is still a key", arguments: [
        "api%5Fkey%3D", "ApiKey%3D", "api_key%3D", "api_key%253D", "api%255Fkey%253D", "X-Emby-Token%3A%20",
    ])
    func encodedKeys(prefix: String) {
        let line = LogRedaction.redact("p?u=http%3A%2F%2Fh%2Fx%3F\(prefix)\(secret)%26x%3D1")
        #expect(!line.contains(secret))
    }

    @Test("a tokenized URL nested inside another query value loses its token")
    func nestedURL() {
        let line = LogRedaction.redact("[Image] fetch failed https://s/Img?ImageUrl=http://h/x?api_key%3D\(secret)%26a%3Db")
        #expect(!line.contains(secret))
        #expect(line.contains("%26a%3Db"))
    }

    @Test("a JSON member is stripped inside its quotes", arguments: [
        #"{"AccessToken":"SECRETabc123def"}"#,
        #"{"api_key":"SECRETabc123def"}"#,
        #"{"password":"SECRETabc123def"}"#,
        #"{"Username":"bob","Pw":"SECRETabc123def"}"#,
        #"{"token" : "SECRETabc123def"}"#,
        "{'AccessToken': 'SECRETabc123def'}",
    ])
    func jsonMember(line: String) {
        let redacted = LogRedaction.redact(line)
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("<redacted>"))
    }

    @Test("the user name next to a JSON password survives")
    func jsonKeepsUserName() {
        let line = LogRedaction.redact(#"{"Username":"bob","Pw":"SECRETabc123def"}"#)
        #expect(line == #"{"Username":"bob","Pw":"<redacted>"}"#)
    }

    @Test("a bearer token is stripped, prose about one is not")
    func bearer() {
        let line = LogRedaction.redact("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRETabc123def.sig")
        #expect(!line.contains(secret))
        #expect(line.hasPrefix("Authorization: Bearer "))
        let prose = "[auth] a bearer token was sent"
        #expect(LogRedaction.redact(prose) == prose)
    }

    @Test("a decoded Seerr cookie goes whole, not only its s: prefix")
    func decodedConnectSID() {
        let line = LogRedaction.redact("Cookie: connect.sid=s:\(secret).sigpart; Path=/")
        #expect(line == "Cookie: connect.sid=<redacted>; Path=/")
    }

    @Test("a raw @ inside a password does not leave the rest of it readable")
    func userInfoWithRawAt() {
        let line = LogRedaction.redact("[x] url=http://bob:p@\(secret)@host/x ok")
        #expect(line == "[x] url=http://bob:<redacted>@host/x ok")
    }

    @Test("a tab separates a header value like a space")
    func tabSeparatedHeader() {
        #expect(!LogRedaction.redact("X-Emby-Token:\t\(secret)").contains(secret))
        #expect(!LogRedaction.redact("api_key\t=\(secret)").contains(secret))
    }

    /// The engine redacts first and this copy runs second. `>` ends a value, so without the
    /// placeholder skip every engine redaction came out as `<redacted>>`.
    @Test("a second pass leaves the first pass's placeholders alone", arguments: [
        "a?api_key=SECRETabc123def&b=1",
        #"Authorization: MediaBrowser Client="Sodalite", Token="SECRETabc123def""#,
        "p?u=h%3Fapi%5Fkey%3DSECRETabc123def%26x%3D1",
        "X-Emby-Token: SECRETabc123def sent",
    ])
    func idempotent(line: String) {
        let once = LogRedaction.redact(line)
        #expect(!once.contains(secret))
        #expect(LogRedaction.redact(once) == once)
        #expect(!once.contains("<redacted>>"))
    }

    @Test("a registered value goes raw and percent-encoded, wherever it sits")
    func registeredSecret() {
        let value = "Zq7/Registered+Value"
        #expect(LogRedaction.register(value))
        defer { LogRedaction.unregister(value) }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let line = LogRedaction.redact("[x] seg=\(value) q=\(encoded) done")
        #expect(line == "[x] seg=<redacted> q=<redacted> done")
    }

    @Test("a value too short to match literally is refused")
    func shortSecretRefused() {
        #expect(!LogRedaction.register("abc"))
    }
}

/// Audit 2026-09-29 SUB-104, SUB-108, SUB-109, ported from AetherEngine's redactor (a4dcba8b): the copy
/// here was measured leaking 22 of 27 credential-bearing inputs. Each case below went through unchanged
/// before the port.
@Suite("Diagnostic log credential stripping, percent escapes, query values and names")
struct LogRedactionEngineAuditTests {

    private let token = "9f2c1ab34de5470fa1b6c8d90e7f2a11"

    // MARK: Nameless shapes inside a percent-encoded URL (SUB-104)

    /// An IPTV proxy or a debrid wrapper carries the upstream URL percent-encoded in its own query.
    /// The key forms of that were covered by NET-1; the shapes that need no key only matched raw.
    @Test("a nameless credential inside a percent-encoded URL goes", arguments: [
        ("url=http://proxy/x?u=http%3A%2F%2Fiptv.example%2Flive%2Falice%2FSECRETpass%2F1234.ts",
         "url=http://proxy/x?u=http%3A%2F%2Fiptv.example%2Flive%2Falice%2F<redacted>%2F1234.ts"),
        ("u=http%3A%2F%2Faddon%2FeyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ%2Fmanifest.json",
         "u=http%3A%2F%2Faddon%2F<redacted>%2Fmanifest.json"),
        ("u=smb%3A%2F%2Fbob%3ASECRETpw%40nas%2Fshare", "u=smb%3A%2F%2Fbob%3A<redacted>%40nas%2Fshare"),
        ("http://addon/v1-eyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ/manifest.json",
         "http://addon/v1-<redacted>/manifest.json"),
    ])
    func namelessShapesThroughEscapes(input: String, expected: String) {
        #expect(LogRedaction.redact(input) == expected)
    }

    @Test("the same shapes encoded twice go too", arguments: [
        "http://iptv.example/live/alice/SECRETpass/1234.ts",
        "http://addon/eyJzdG9yZXMiOlsiYSJdLCJjIjoiU0VDUkVUeHl6IiwidCI6InQifQ/manifest.json",
        "smb://bob:SECRETpw@nas/share",
    ])
    func namelessShapesEncodedTwice(upstream: String) {
        let once = upstream.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let twice = once.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let out = LogRedaction.redact("[HLSIngest] #1 load url=https://mfp.example/p?d=\(twice) startPos=nil")
        for secret in ["SECRETpass", "SECRETpw", "U0VDUkVUeHl6"] { #expect(!out.contains(secret), "\(out)") }
        #expect(out.contains("<redacted>"))
        #expect(out.hasSuffix(" startPos=nil"))
    }

    /// `"\(error)"` of a URLError prints the failing URL twice through its userInfo.
    @Test("an interpolated URLError loses the encoded upstream credential of its failing URL")
    func urlErrorDescription() {
        let upstream = "http://iptv/live/alice/SECRETpass/1.ts"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let failing = "http://127.0.0.1:1/live/playlist.m3u8?u=\(upstream)"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSURLErrorFailingURLStringErrorKey: failing,
                                       NSURLErrorFailingURLErrorKey: URL(string: failing)!])
        let out = LogRedaction.redact("[HLSIngest] carriage probe inconclusive: \(error)")
        #expect(!out.contains("SECRETpass"), "\(out)")
    }

    @Test("an escape-heavy line with nothing secret in it comes back unchanged", arguments: [
        "[ffmpeg] Opening 'https://s/Videos/My%20Movie%20(2009)/stream.mkv' for reading",
        "[x] url=https://s/Shows/Show%20Name/Season%2001/Show%20Name%20-%20S01E01.mkv ok",
        "[x] path=%2Fmedia%2Flive%2Fchannel1%2Findex.m3u8 ok",
        "[HLSLocalServer] GET /0123/aether-origin-relay?ref=eW91IGNhbm5vdCByZWFkIHRoaXM_3kJ-qZ HTTP/1.1 fd=9",
        "[x] buffer 100% full, 5%token budget, 12%3 left",
    ])
    func escapesWithoutSecretsSurvive(line: String) {
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("a registered value inside a percent-encoded URL goes through the decoded view too")
    func registeredSecretThroughEscapes() {
        let value = "Zq7/Decoded+View"
        #expect(LogRedaction.register(value))
        defer { LogRedaction.unregister(value) }
        // Lowercase hex is neither encoded form `register` knows, so only the decoded view reads it.
        let line = LogRedaction.redact("[x] u=http%3A%2F%2Fh%2FZq7%2fDecoded%2bView%2F1.ts ok")
        #expect(!line.contains("Decoded"), "\(line)")
        #expect(line.hasSuffix(" ok"))
    }

    // MARK: Query values that hold a terminator (SUB-108)

    @Test("a query password holding : ; , ) or > goes whole", arguments: [":", ";", ",", ")", ">"])
    func queryPasswordWithPunctuation(mark: String) {
        let out = LogRedaction.redact("https://h/get.php?username=u&password=SECRET\(mark)tail123&type=m3u")
        #expect(out == "https://h/get.php?username=u&password=<redacted>&type=m3u")
    }

    @Test("punctuation that prose puts after a value still ends it")
    func proseAfterAValue() {
        #expect(LogRedaction.redact("[x] fetch failed (api_key=abc), retrying")
                == "[x] fetch failed (api_key=<redacted>), retrying")
        #expect(LogRedaction.redact("[x] seen <token=abc>") == "[x] seen <token=<redacted>>")
        #expect(LogRedaction.redact("[x] https://s/i?ApiKey=abc: timeout") == "[x] https://s/i?ApiKey=<redacted>: timeout")
    }

    @Test("the password field of AuthenticateByName holds punctuation too", arguments: [":", ";", ",", ")", ">"])
    func shortPasswordKeyWithPunctuation(mark: String) {
        #expect(LogRedaction.redact("https://h/a?pw=SECRET\(mark)tail123&x=1") == "https://h/a?pw=<redacted>&x=1")
    }
}
