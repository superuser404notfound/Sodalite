import Foundation

/// Strips credentials out of a diagnostic line before it enters `LogTap`.
///
/// The log exists to be handed to someone else: a screenshot in a GitHub issue, a paste into Discord
/// through the iOS Copy button. Jellyfin puts the access token in the QUERY (`api_key=` on every stream
/// URL, and `ApiKey=` as well from the image service), so an unfiltered log is a live credential the
/// moment a user shares it.
///
/// AetherEngine redacts its own `EngineLog` lines with the same matcher, so the lines arriving through
/// `EngineLog.handler` are normally already clean. This stays regardless: the lines the host composes
/// itself (`[Image] fetch failed <url>`, `[discovery]`, `[session]`) never pass through the engine, and
/// an engine pin that lags a redactor fix must not reopen the leak here. Running twice is harmless, the
/// second pass skips a placeholder rather than redacting it again.
///
/// The matchers below are the engine's (a4dcba8b, audit 2026-09-29 SUB-104, SUB-108, SUB-109) byte for
/// byte in behaviour, so the two funnels cannot drift apart a third time; the additions on top of it are
/// marked `Sodalite-only`. Keep a change to a shared matcher in both places.
///
/// Placed on the `LogTap.note(_:)` funnel rather than at each call site on purpose, so a line added
/// tomorrow is covered without anyone remembering this file. Over-redaction is the safe failure here,
/// under-redaction is the leak. The value is replaced whole rather than truncated to a prefix: a prefix
/// still narrows a brute-force and answers no question a playback bug asks. Everything else about the
/// URL (host, path, item id, container, bitrate, subtitle index) survives, which is the part that
/// answers the bug.
nonisolated enum LogRedaction {

    static let placeholder = "<redacted>"

    /// Jellyfin and Seerr credential names plus the generic ones, so a future backend is covered too.
    /// Held as lowercase ASCII bytes and matched longest first, so `x-mediabrowser-token` wins over its
    /// `token` suffix. `token` alone is deliberately broad and only fires on a boundary, so identifiers
    /// such as `hasToken` and `refreshTokenAt` are left alone. Sodalite-only: `mediabrowsertoken`,
    /// `api-key`, and `pw` (the password field of Jellyfin's `AuthenticateByName` body).
    private static let keys: [[UInt8]] = [
        "x-mediabrowser-token", "mediabrowsertoken", "x-emby-token", "access_token", "accesstoken",
        "connect.sid", "signature", "password", "api_key", "api-key", "apikey", "secret", "token", "pw",
    ].map { Array($0.utf8) }

    private static let connectSID = Array("connect.sid".utf8)
    private static let placeholderBytes = Array(placeholder.utf8)

    /// Works on UTF-8 bytes, not Characters, and allocates the output only once something actually
    /// matches. That is not premature: a Character-level pass building a lowercased String per position
    /// cost enough on this hot path to shift request timing in an AetherEngine test, which is how the
    /// first version of this file was caught. Every engine line passes through `note(_:)`, so anything
    /// per-line here is per-line for the whole session.
    ///
    /// Audit SUB-104: a URL carried percent-encoded inside another URL's query hides every shape that
    /// needs no key (`%2F` is not a `/`, `%40` is not an `@`, `%2F` ends in a base64 letter). A line
    /// holding a valid escape therefore also runs the nameless matchers over a decoded view built once,
    /// and each hit maps back to whole escapes. The key matcher stays raw-only: its depth-aware
    /// terminators are the NET-1 rule, and the view is produced once and never decoded again. A line
    /// without an escape, which is nearly every line, takes the one raw pass and no view.
    static func redact(_ line: String) -> String {
        let bytes = Array(line.utf8)
        let secrets = registeredSecrets
        var spans = scan(bytes, secrets: secrets, keys: true)
        if let view = DecodedView(bytes) {
            let hits = scan(view.decoded, secrets: secrets, keys: false)
            if !hits.isEmpty {
                spans += hits.map { view.rawStart[$0.lowerBound] ..< view.rawStart[$0.upperBound] }
                spans.sort { $0.lowerBound < $1.lowerBound }
            }
        }
        guard !spans.isEmpty else { return line }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var copiedUpTo = 0
        var current = spans[0]
        for span in spans.dropFirst() {
            if span.lowerBound <= current.upperBound {
                current = current.lowerBound ..< max(current.upperBound, span.upperBound)
                continue
            }
            out.append(contentsOf: bytes[copiedUpTo ..< current.lowerBound])
            out.append(contentsOf: placeholderBytes)
            copiedUpTo = current.upperBound
            current = span
        }
        out.append(contentsOf: bytes[copiedUpTo ..< current.lowerBound])
        out.append(contentsOf: placeholderBytes)
        out.append(contentsOf: bytes[current.upperBound...])
        return String(decoding: out, as: UTF8.self)
    }

    /// The secret spans of one pass, in order and disjoint. Empty, and allocation-free, for a line
    /// with nothing in it.
    private static func scan(_ bytes: [UInt8], secrets: [[UInt8]], keys: Bool) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = 0
        while i < bytes.count {
            // A placeholder the engine already wrote is passed over whole, or the `>` that ends it
            // would read as a value terminator and leave `<redacted>>` behind.
            if hasPrefix(placeholderBytes, in: bytes, at: i) {
                i += placeholderBytes.count
                continue
            }
            guard let value = match(in: bytes, at: i, secrets: secrets, keys: keys) else {
                i += 1
                continue
            }
            spans.append(value)
            i = value.upperBound
        }
        return spans
    }

    /// Several shapes, because a credential does not always arrive next to a name. The key matcher
    /// covers `api_key=…`, `X-Emby-Token: …` and the cookie; the scheme matcher covers
    /// `Authorization: Bearer …`; the payload matcher covers an encoded blob that no name
    /// points at, which is how a path segment carries one; the userinfo matcher covers
    /// `smb://user:secret@host`, where it sits in the authority; the path matcher covers the Xtream
    /// layout; a registered secret is found wherever it sits.
    @inline(__always)
    private static func match(in bytes: [UInt8], at index: Int, secrets: [[UInt8]], keys: Bool)
        -> Range<Int>?
    {
        if let secret = registeredSecretRange(in: bytes, at: index, secrets: secrets) { return secret }
        if keys, let key = matchedKey(in: bytes, at: index),
           let value = valueRange(in: bytes, keyStart: index, keyEnd: index + key.length, key: key.key) {
            return value
        }
        return bearerTokenRange(in: bytes, at: index)
            ?? encodedPayloadRange(in: bytes, at: index)
            ?? userInfoSecretRange(in: bytes, at: index)
            ?? xtreamPathSecretRange(in: bytes, at: index)
    }

    /// Every logical character of a line once, escapes followed through `%25` layers by
    /// `logicalByte`, with the raw offset each one starts at, so a range found in `decoded` maps back
    /// to whole escapes. Nil for a line without a valid escape, which keeps the raw pass alone.
    private struct DecodedView {
        let decoded: [UInt8]
        /// `decoded.count + 1` entries; the last is the raw length.
        let rawStart: [Int]

        init?(_ bytes: [UInt8]) {
            guard bytes.withUnsafeBufferPointer({ memchr($0.baseAddress, 0x25, $0.count) }) != nil
            else { return nil }
            var k = 0
            var found = false
            while k + 2 < bytes.count {
                if bytes[k] == LogRedaction.percent, LogRedaction.hexValue(bytes[k + 1]) != nil,
                   LogRedaction.hexValue(bytes[k + 2]) != nil {
                    found = true
                    break
                }
                k += 1
            }
            guard found else { return nil }
            var decoded: [UInt8] = []
            decoded.reserveCapacity(bytes.count)
            var rawStart: [Int] = []
            rawStart.reserveCapacity(bytes.count + 1)
            var i = 0
            while i < bytes.count {
                let char = LogRedaction.logicalByte(in: bytes, at: i)
                decoded.append(char.byte)
                rawStart.append(i)
                i += char.width
            }
            rawStart.append(bytes.count)
            self.decoded = decoded
            self.rawStart = rawStart
        }
    }

    /// Raw length of the key starting here, and which key, or nil. The key must start on a boundary,
    /// else `token` would fire inside `hasToken`. A separator such as the `-` in `X-Emby-Token` or the
    /// `_` in `api_key` is a boundary; an ASCII letter or digit is not, unless it closes a percent
    /// escape whose decoded character is a separator.
    ///
    /// Audit NET-1: the key is read through `logicalByte`, so a URL logged inside another URL's query
    /// (`%26api%5Fkey%3D…`, or `%2526api%255Fkey%253D…` encoded twice) is matched like the plain form.
    private static func matchedKey(in bytes: [UInt8], at index: Int) -> (length: Int, key: [UInt8])? {
        let first = logicalByte(in: bytes, at: index)
        guard keyInitials.contains(lowercased(first.byte)) else { return nil }
        if precededByWordCharacter(bytes, at: index) { return nil }
        for key in keys {
            var j = index
            var matched = true
            for keyByte in key {
                guard j < bytes.count else { matched = false; break }
                let char = logicalByte(in: bytes, at: j)
                guard lowercased(char.byte) == keyByte else { matched = false; break }
                j += char.width
            }
            if matched { return (j - index, key) }
        }
        return nil
    }

    private static let keyInitials = Set(keys.map { $0[0] })

    /// The span holding the secret, given the key's bounds. Covers the query form
    /// (`api_key=abc&next=1`), both header forms (`Token="abc"`, `X-Emby-Token: abc`), the cookie
    /// form (`connect.sid=abc; Path=/`) and, Sodalite-only, a JSON member (`"AccessToken":"abc"`).
    /// Nil when there is no assignment or the value is empty, so `api_key=` and a bare mention in
    /// prose are left alone.
    ///
    /// Characters are read through `logicalByte`. A terminator ends the value only when it sits under
    /// no more encoding layers than the `=` did: inside a plain query `%26` is part of the value, inside
    /// an encoded one it is the `&` that ends it. With no escape in sight this is the byte scan it was.
    private static func valueRange(in bytes: [UInt8], keyStart: Int, keyEnd: Int, key: [UInt8]) -> Range<Int>? {
        var i = keyEnd
        // Sodalite-only: a JSON key closes its own quote before the colon, so that quote is skipped
        // when the same quote opened the key.
        if keyStart > 0, bytes[keyStart - 1] == UInt8(ascii: "\"") || bytes[keyStart - 1] == UInt8(ascii: "'"),
           i < bytes.count, bytes[i] == bytes[keyStart - 1] {
            i += 1
        }
        while i < bytes.count, case let char = logicalByte(in: bytes, at: i), isBlank(char.byte) {
            i += char.width
        }
        guard i < bytes.count else { return nil }
        let separator = logicalByte(in: bytes, at: i)
        guard separator.byte == UInt8(ascii: "=") || separator.byte == UInt8(ascii: ":") else {
            return nil
        }
        let isHeaderSeparator = separator.byte == UInt8(ascii: ":")
        let depth = separator.depth
        i += separator.width

        // Only a header separator may be followed by spaces. After `=` the value starts immediately:
        // a URL query and a cookie never space it out, and skipping here would let prose such as
        // "api_key= (missing)" read as a credential and swallow the rest of the line.
        var afterSpaces = i
        while afterSpaces < bytes.count, case let char = logicalByte(in: bytes, at: afterSpaces),
              isBlank(char.byte) {
            afterSpaces += char.width
        }
        var quote: UInt8?
        if afterSpaces < bytes.count, case let char = logicalByte(in: bytes, at: afterSpaces),
           char.depth <= depth, char.byte == UInt8(ascii: "\"") || char.byte == UInt8(ascii: "'") {
            quote = char.byte
            i = afterSpaces + char.width
        } else if isHeaderSeparator {
            i = afterSpaces
        }
        let start = i
        if hasPrefix(placeholderBytes, in: bytes, at: start) { return nil }

        // Sodalite-only: a decoded session cookie is `s:<sid>.<sig>`, and the colon would otherwise end
        // the value after the `s`.
        if key == connectSID, start + 1 < bytes.count,
           bytes[start] == UInt8(ascii: "s"), bytes[start + 1] == UInt8(ascii: ":") {
            i += 2
        }

        while i < bytes.count {
            let char = logicalByte(in: bytes, at: i)
            if char.depth <= depth {
                if let quote, char.byte == quote { break }
                if quote == nil, isValueTerminator(char.byte),
                   endsValue(char, at: i, in: bytes, afterHeaderSeparator: isHeaderSeparator) {
                    break
                }
            }
            i += char.width
        }
        return start < i ? start ..< i : nil
    }

    /// Audit SUB-108: `: ; , ) >` are legal unescaped inside a query value, and a user-chosen
    /// password holds them, so after `=` one of them ends the value only where prose follows it (a
    /// terminator, a blank or the end of the line): `…&api_key=abc: timeout` and
    /// `connect.sid=abc; Path=/` still give their text back, `password=Pa:ss,word&…` goes whole. The
    /// header form keeps the wide set, since a header value is not a query value.
    private static func endsValue(_ char: (byte: UInt8, width: Int, depth: Int), at index: Int,
                                  in bytes: [UInt8], afterHeaderSeparator: Bool) -> Bool {
        guard !afterHeaderSeparator, isSoftTerminator(char.byte) else { return true }
        let next = index + char.width
        guard next < bytes.count else { return true }
        return isValueTerminator(logicalByte(in: bytes, at: next).byte)
    }

    // MARK: Bearer credentials (Sodalite-only)

    private static let bearer = Array("bearer".utf8)

    /// A bearer token shorter than this is prose ("bearer token"), not a credential.
    private static let minimumBearerLength = 16

    /// The token after `Bearer `, or nil. The scheme has no `=` or `:` of its own, so the key matcher
    /// cannot see it; the length floor keeps "a bearer token was sent" whole.
    private static func bearerTokenRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard lowercased(bytes[index]) == bearer[0], index + bearer.count < bytes.count else { return nil }
        if index > 0, isLetterOrDigit(bytes[index - 1]) { return nil }
        for offset in 1 ..< bearer.count where lowercased(bytes[index + offset]) != bearer[offset] { return nil }
        var i = index + bearer.count
        guard isBlank(bytes[i]) else { return nil }
        while i < bytes.count, isBlank(bytes[i]) { i += 1 }
        let start = i
        while i < bytes.count, isToken68(bytes[i]) { i += 1 }
        return i - start >= minimumBearerLength ? start ..< i : nil
    }

    private static func isToken68(_ b: UInt8) -> Bool {
        isBase64URL(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: "~") || b == UInt8(ascii: "+")
            || b == UInt8(ascii: "/") || b == UInt8(ascii: "=")
    }

    // MARK: Percent escapes

    fileprivate static let percent = UInt8(ascii: "%")
    private static let space = UInt8(ascii: " ")

    /// Sodalite-only: a tab separates a header value as readily as a space does.
    private static func isBlank(_ b: UInt8) -> Bool {
        b == space || b == 0x09
    }

    /// A value encoded more often than this is not one a URL builder produces by accident.
    private static let maximumEncodingDepth = 4

    /// One character as a URL decoder would see it: a raw byte, or a `%XX` escape, followed through
    /// `%25` when the value was encoded more than once. `depth` is the number of layers (0 = raw).
    fileprivate static func logicalByte(in bytes: [UInt8], at index: Int)
        -> (byte: UInt8, width: Int, depth: Int)
    {
        let raw = bytes[index]
        guard raw == percent, index + 2 < bytes.count,
              let hi = hexValue(bytes[index + 1]), let lo = hexValue(bytes[index + 2]) else {
            return (raw, 1, 0)
        }
        var value = hi << 4 | lo
        var width = 3
        var depth = 1
        while value == percent, depth < maximumEncodingDepth, index + width + 1 < bytes.count,
              let nextHi = hexValue(bytes[index + width]), let nextLo = hexValue(bytes[index + width + 1]) {
            value = nextHi << 4 | nextLo
            width += 2
            depth += 1
        }
        return (value, width, depth)
    }

    /// Whether the character in front of `index` is a letter or digit, reading a percent escape that
    /// ends there (`%26`, `%2526`) as the character it decodes to.
    private static func precededByWordCharacter(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index > 0, isLetterOrDigit(bytes[index - 1]) else { return false }
        guard index >= 3, let hi = hexValue(bytes[index - 2]), let lo = hexValue(bytes[index - 1]) else {
            return true
        }
        var k = index - 3
        var layers = 1
        while bytes[k] != percent {
            guard layers < maximumEncodingDepth, k >= 2,
                  bytes[k - 1] == UInt8(ascii: "2"), bytes[k] == UInt8(ascii: "5") else { return true }
            k -= 2
            layers += 1
        }
        return isLetterOrDigit(hi << 4 | lo)
    }

    fileprivate static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The secret inside a URL's userinfo, given an index that may start `://`. `smb://user:pw@host`
    /// and `http://user:pw@host` put the credential in the authority, where no key precedes it, so
    /// the key matcher above cannot see it. The user name is left readable: it identifies the account
    /// a line is about, and a diagnostic log that cannot say which account failed is worth less.
    /// Nil unless an `@` really terminates an authority, so prose such as "see http://a.test and
    /// foo@bar" is untouched: the scan stops at the first character that cannot appear in userinfo.
    /// Sodalite-only: the userinfo runs to the LAST `@` of the authority, so a raw `@` inside a
    /// password (some tools print it unencoded) does not leave the rest of it readable.
    private static func userInfoSecretRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard index + 3 <= bytes.count,
              bytes[index] == UInt8(ascii: ":"),
              bytes[index + 1] == UInt8(ascii: "/"),
              bytes[index + 2] == UInt8(ascii: "/") else { return nil }
        let start = index + 3
        var i = start
        var colon: Int?
        var lastAt: Int?
        while i < bytes.count, !isAuthorityTerminator(bytes[i]) {
            if bytes[i] == UInt8(ascii: "@") { lastAt = i }
            if bytes[i] == UInt8(ascii: ":"), colon == nil, lastAt == nil { colon = i }
            i += 1
        }
        guard let end = lastAt else { return nil }
        // With a colon the password is everything after it; without one the whole userinfo is the
        // secret (a bare token in the authority), and then the user name cannot be spared.
        let secretStart = colon.map { $0 + 1 } ?? start
        return secretStart < end ? secretStart ..< end : nil
    }

    // MARK: Registered secrets

    /// Shortest value `register` accepts. A literal match has no context to go by, so a one- or
    /// two-byte value would black out every occurrence of that text in every line.
    static let minimumSecretLength = 4

    private static let secretsLock = NSLock()
    nonisolated(unsafe) private static var _secrets: [String: [UInt8]] = [:]

    /// Snapshot taken once per line, so a register racing a redact sees the old set or the new one,
    /// never half of it. Sorted longest first, so a secret that contains another goes whole.
    private static var registeredSecrets: [[UInt8]] {
        secretsLock.lock(); defer { secretsLock.unlock() }
        return _secrets.isEmpty ? [] : _secrets.values.sorted { $0.count > $1.count }
    }

    /// Registers the value and its percent-encoded form, which is how it appears inside a URL path or
    /// query when it holds a character a URL cannot carry raw. Returns false for a value too short to
    /// match literally.
    @discardableResult
    static func register(_ secret: String) -> Bool {
        let forms = literalForms(of: secret)
        guard !forms.isEmpty else { return false }
        secretsLock.lock(); defer { secretsLock.unlock() }
        for form in forms { _secrets[form] = Array(form.utf8) }
        return true
    }

    static func unregister(_ secret: String) {
        let forms = literalForms(of: secret)
        secretsLock.lock(); defer { secretsLock.unlock() }
        for form in forms { _secrets[form] = nil }
    }

    static func unregisterAll() {
        secretsLock.lock(); defer { secretsLock.unlock() }
        _secrets.removeAll()
    }

    private static func literalForms(of secret: String) -> Set<String> {
        guard secret.utf8.count >= minimumSecretLength else { return [] }
        var forms: Set<String> = [secret]
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { forms.insert(encoded) }
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.insert(encoded) }
        return forms
    }

    /// The span of a registered secret starting here, or nil. Exact bytes, no boundary rule: the host
    /// said this value must never be logged, so it goes even inside a longer word.
    private static func registeredSecretRange(in bytes: [UInt8], at index: Int, secrets: [[UInt8]]) -> Range<Int>? {
        for secret in secrets where index + secret.count <= bytes.count && bytes[index] == secret[0] {
            var matched = true
            for offset in 1 ..< secret.count where bytes[index + offset] != secret[offset] {
                matched = false
                break
            }
            if matched { return index ..< index + secret.count }
        }
        return nil
    }

    // MARK: Encoded payloads

    /// Shortest encoded run worth decoding. `{"a":"b"}` is nine bytes, so twelve characters; anything
    /// shorter cannot be a JSON object and a credential blob is far longer than either.
    private static let minimumEncodedLength = 12

    /// The span of an encoded payload starting here, or nil.
    ///
    /// A path segment or a query value holding base64url-encoded JSON carries structure the URL never
    /// declares. No name precedes it, so the key matcher cannot see it, and the list of names cannot
    /// be extended to reach it either: the names are INSIDE the payload and belong to whoever wrote it.
    /// The case this was reported for decodes to the keys `stores`, `c` and `t`. The encoding is the
    /// only honest signal, and an opaque blob answers no question a playback report asks, so the whole
    /// run goes.
    ///
    /// Gated hard before it allocates: base64url of `{` always starts `e` and of `[` always `W`, so one
    /// byte comparison rejects very nearly every position in the line.
    private static func encodedPayloadRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "W") else { return nil }
        // A letter or digit in front means the run started earlier. A `-` or `_` does not: a blob
        // glued to a version prefix (`/v1-eyJ…`) is still a blob (audit SUB-104).
        if index > 0, isLetterOrDigit(bytes[index - 1]) { return nil }

        var end = index
        while end < bytes.count, isBase64URL(bytes[end]) { end += 1 }
        guard end - index >= minimumEncodedLength, decodesToJSON(bytes[index ..< end]) else { return nil }

        // A JSON web token is three of these joined by dots, and the signature at the end is the part
        // worth stealing, so the whole token goes rather than the header that happened to match.
        var extended = end
        while extended < bytes.count, bytes[extended] == UInt8(ascii: ".") {
            var run = extended + 1
            while run < bytes.count, isBase64URL(bytes[run]) { run += 1 }
            guard run > extended + 1 else { break }
            extended = run
        }
        return index ..< extended
    }

    /// Whether the run decodes as base64url into a JSON object or array. `JSONSerialization` without
    /// `.fragmentsAllowed` is the test rather than a resemblance check: a bare number or string would
    /// otherwise let ordinary text through, and an episode file named `Eyewitness…` gets as far as the
    /// decode and no further.
    private static func decodesToJSON(_ run: ArraySlice<UInt8>) -> Bool {
        var encoded = String(decoding: run, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isBase64URL(_ b: UInt8) -> Bool {
        isLetterOrDigit(b) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    // MARK: Xtream Codes paths

    /// Path prefixes of the Xtream Codes stream layout, each paired with the zero-based positions of
    /// the segments after it that hold a credential. `/live/`, `/movie/`, `/series/` and `/timeshift/`
    /// carry `{user}/{password}/...`; the HLS redirect targets carry a session token first, and
    /// `/hlsr/` then repeats `{user}/{password}` behind it.
    private static let xtreamLayouts: [(prefix: [UInt8], secretSegments: [Int])] = [
        ("/live/", [1]), ("/movie/", [1]), ("/series/", [1]), ("/timeshift/", [1]),
        ("/hls/", [0]), ("/hlsr/", [0, 2]),
    ].map { (Array($0.0.utf8), $0.1) }

    /// The span from the first credential segment through the last one, given an index that may
    /// start one of `xtreamLayouts`' prefixes, or nil. The user name in front of the password is left
    /// readable for the same reason as in `userInfoSecretRange`; on `/hlsr/` it sits between the token
    /// and the password and goes with them, since one line yields one span.
    ///
    /// A credential segment only counts when a further path segment follows it, because that is what
    /// the layout guarantees and what an ordinary HLS path lacks: `/live/master.m3u8` and
    /// `/live/channel1/index.m3u8` stay whole. Over-redacting some other three-deep `/live/` path is
    /// the accepted cost.
    private static func xtreamPathSecretRange(in bytes: [UInt8], at index: Int) -> Range<Int>? {
        guard bytes[index] == UInt8(ascii: "/") else { return nil }
        for layout in xtreamLayouts where hasPrefix(layout.prefix, in: bytes, at: index) {
            var segments: [Range<Int>] = []
            var i = index + layout.prefix.count
            let needed = layout.secretSegments.max()! + 2
            while segments.count < needed {
                let start = i
                while i < bytes.count, bytes[i] != UInt8(ascii: "/"), !isPathTerminator(bytes[i]) { i += 1 }
                guard i > start else { break }
                segments.append(start ..< i)
                guard i < bytes.count, bytes[i] == UInt8(ascii: "/") else { break }
                i += 1
            }
            guard segments.count >= needed else { continue }
            return segments[layout.secretSegments.min()!].lowerBound ..< segments[layout.secretSegments.max()!].upperBound
        }
        return nil
    }

    private static func hasPrefix(_ prefix: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for offset in 0 ..< prefix.count where bytes[index + offset] != prefix[offset] { return false }
        return true
    }

    /// Ends a URL path: the query, the fragment, or whatever the log line puts after the URL.
    private static func isPathTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: "\""), UInt8(ascii: "'"),
             UInt8(ascii: ","), UInt8(ascii: ")"), UInt8(ascii: ">"), UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    /// Ends an authority component. `@` is deliberately absent: it is what the scan is looking for.
    private static func isAuthorityTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"), UInt8(ascii: "\""),
             UInt8(ascii: "'"), UInt8(ascii: ","), UInt8(ascii: ")"), UInt8(ascii: ">"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    /// Audit SUB-108: the terminators that are also legal inside a query value.
    private static func isSoftTerminator(_ b: UInt8) -> Bool {
        b == UInt8(ascii: ":") || b == UInt8(ascii: ";") || b == UInt8(ascii: ",")
            || b == UInt8(ascii: ")") || b == UInt8(ascii: ">")
    }

    /// `:` counts, so `…&api_key=abc: timeout` gives the token back and keeps the error text, though
    /// after `=` only where prose follows it (`endsValue`). The decoded cookie's `s:` prefix is passed
    /// over in `valueRange`.
    private static func isValueTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "&"), UInt8(ascii: ";"), UInt8(ascii: ","), UInt8(ascii: ")"),
             UInt8(ascii: ">"), UInt8(ascii: ":"), UInt8(ascii: "\""), UInt8(ascii: "'"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    private static func isLetterOrDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
    }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ? b + 32 : b
    }
}
