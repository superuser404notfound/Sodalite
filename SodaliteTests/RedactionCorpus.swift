import Foundation

/// Shared redaction corpus (audit PTD-R201). Every row is an input line and what `LogRedaction` must
/// leave of it. The engine keeps its own copy of the matcher and the two drifted once already
/// (PTD-201). This file holds no Sodalite types, so the engine's tests can take it as it is. Rows
/// whose name starts with `Sodalite-only` cover shapes the engine does not redact, and the PTD-203
/// rows fail on the engine until it gets the same fix. Drop or flag those there.
nonisolated struct RedactionCorpusCase: Sendable, CustomStringConvertible {
    let name: String
    let input: String
    let expected: String

    init(_ name: String, input: String, expected: String) {
        self.name = name
        self.input = input
        self.expected = expected
    }

    var description: String { name }
}

nonisolated enum RedactionCorpus {
    static let cases: [RedactionCorpusCase] = [
        .init("SUB-205 camelCase apiToken",
              input: "apiToken=abc123secret",
              expected: "apiToken=<redacted>"),
        .init("SUB-205 camelCase userToken",
              input: "userToken=abc123 x",
              expected: "userToken=<redacted> x"),
        .init("SUB-205 camelCase plexToken",
              input: "plexToken=abc123&x=1",
              expected: "plexToken=<redacted>&x=1"),
        .init("SUB-205 camelCase idToken",
              input: "idToken=abc123",
              expected: "idToken=<redacted>"),
        .init("SUB-205 camelCase jwtToken",
              input: "jwtToken=zzz",
              expected: "jwtToken=<redacted>"),
        .init("SUB-205 flag name hasToken stays",
              input: "hasToken=true",
              expected: "hasToken=true"),
        .init("SUB-205 flag name refreshTokenAt stays",
              input: "refreshTokenAt=5",
              expected: "refreshTokenAt=5"),
        .init("SUB-205 whole Cookie header",
              input: "Cookie: lang=en; PHPSESSID=abc123; connect.sid=s%3Aabc.def",
              expected: "Cookie: <redacted>"),
        .init("SUB-205 Set-Cookie keeps attributes",
              input: "Set-Cookie: sid=abc123; Path=/; HttpOnly",
              expected: "Set-Cookie: <redacted>; Path=/; HttpOnly"),
        .init("SUB-205 Optional wrapper",
              input: "api_key: Optional(\"abc123\")",
              expected: "api_key: Optional(\"<redacted>\")"),
        .init("SUB-205 escaped quote in JSON",
              input: "{\"password\":\"ab\\\"cd\"}",
              expected: "{\"password\":\"<redacted>\"}"),
        .init("SUB-205 short Basic credential",
              input: "Authorization: Basic dXNlcjpwdw==",
              expected: "Authorization: Basic <redacted>"),
        .init("SUB-205 raw @ in smb password",
              input: "smb://user:p@ss@host/share",
              expected: "smb://user:<redacted>@host/share"),
        .init("PTD-203 refresh_token member",
              input: "{\"refresh_token\":\"ghijkl\"}",
              expected: "{\"refresh_token\":\"<redacted>\"}"),
        .init("PTD-203 client_secret member",
              input: "{\"client_secret\":\"zzz\"}",
              expected: "{\"client_secret\":\"<redacted>\"}"),
        .init("PTD-203 id_token member",
              input: "{\"id_token\":\"ghijkl\"}",
              expected: "{\"id_token\":\"<redacted>\"}"),
        .init("PTD-203 clientSecret member",
              input: "{\"clientSecret\":\"zzz\"}",
              expected: "{\"clientSecret\":\"<redacted>\"}"),
        .init("PTD-203 a_token member",
              input: "{\"a_token\":\"ghijkl\"}",
              expected: "{\"a_token\":\"<redacted>\"}"),
        .init("PTD-203 several members",
              input: "{\"access_token\":\"abcdef\",\"refresh_token\":\"ghijkl\",\"client_secret\":\"zzz\"}",
              expected: "{\"access_token\":\"<redacted>\",\"refresh_token\":\"<redacted>\",\"client_secret\":\"<redacted>\"}"),
        .init("Sodalite-only pw member",
              input: "{\"pw\":\"x\"}",
              expected: "{\"pw\":\"<redacted>\"}"),
        .init("plain token member",
              input: "{\"token\":\"ghijkl\"}",
              expected: "{\"token\":\"<redacted>\"}"),
        .init("query refresh_token",
              input: "refresh_token=ghijkl",
              expected: "refresh_token=<redacted>"),
        .init("Image fetch failed keeps the tail",
              input: "[Image] fetch failed https://s/Items/1/Images/Primary?api_key=9f2c1ab34de5470fa1b6c8d90e7f2a11: timeout",
              expected: "[Image] fetch failed https://s/Items/1/Images/Primary?api_key=<redacted>: timeout"),
        .init("Sodalite-only connect.sid decoded s: prefix",
              input: "Cookie: connect.sid=s:abc.def; Path=/",
              expected: "Cookie: connect.sid=<redacted>; Path=/"),
        .init("prose is left alone",
              input: "plain line with no secret at all",
              expected: "plain line with no secret at all"),
    ]
}
