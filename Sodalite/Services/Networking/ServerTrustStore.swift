import CryptoKit
import Foundation
import Security
import Synchronization

/// The SHA-256 of a certificate, in the two forms this app needs it: one to compare, one to read.
nonisolated enum CertificateFingerprint {

    /// Lowercase hex of the DER SHA-256. The whole certificate rather than its public key: what the
    /// user was shown and accepted is this exact certificate, and a renewal that keeps the key is
    /// still a new certificate the user has not seen.
    static func sha256(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The leaf of a trust object, which is the certificate the origin is presenting as itself.
    static func sha256(ofLeafIn trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return sha256(of: leaf)
    }

    /// Uppercase colon-separated byte pairs. Nobody reads 64 hex characters as one run, and the
    /// point of showing a fingerprint at all is that it can be held against what a server's own
    /// admin page says.
    static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(2, hex.count - offset))
            return hex[start..<end].uppercased()
        }.joined(separator: ":")
    }
}

/// Where the pins live. Fronted so the store can be tested without a keychain, and so the keychain
/// half stays with `DependencyContainer` like every other credential in this app.
protocol TrustPinStorage: Sendable {
    nonisolated func loadPins() -> [String: String]
    nonisolated func savePins(_ pins: [String: String])
}

/// Which server certificates this device has been told to accept, keyed by the host that offered
/// them.
///
/// Per host and not per server: a `JellyfinServer` carries a LAN and a WAN address, and typically
/// only the first is behind a private certificate. Trusting the server as a whole would quietly
/// lower the bar for the address that has a real certificate, which is the one an attacker would
/// have to be on the path of.
///
/// The fingerprint is the decision. An entry does not say "this host may present anything", it says
/// "this host may present THIS certificate", so a different one later is a question the user gets
/// asked again rather than an answer they already gave.
nonisolated final class ServerTrustStore: @unchecked Sendable {

    private let storage: any TrustPinStorage
    private let lock = NSLock()
    private var pins: [String: String]
    /// What was offered and not accepted, so the sheet can show a fingerprint the user has not
    /// trusted yet. In memory only: a certificate the app merely saw must not read, after a
    /// relaunch, like one it was told about.
    private var refusals: [String: String] = [:]

    init(storage: any TrustPinStorage) {
        self.storage = storage
        self.pins = storage.loadPins()
    }

    /// `host:port`, which is the granularity a certificate is offered at. The port comes from the
    /// scheme when the URL omits it, so the address the user typed and the challenge the connection
    /// raises name the same host.
    static func hostKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let port = url.port ?? (scheme == "http" ? 80 : scheme == "https" ? 443 : nil)
        guard let port else { return nil }
        return "\(host):\(port)"
    }

    static func hostKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    func pinnedFingerprint(forHost host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pins[host]
    }

    /// Records the decision and writes it through at once. A pin that only reached memory would ask
    /// the user again on the next launch, which teaches them to accept the sheet without reading it.
    func pin(_ fingerprint: String, forHost host: String) {
        lock.lock()
        pins[host] = fingerprint
        refusals[host] = nil
        let snapshot = pins
        lock.unlock()
        storage.savePins(snapshot)
    }

    /// A factory reset. The keychain item goes with the reset's wipe, but the pins in memory kept
    /// every old certificate accepted until relaunch, and the next `pin` wrote them all back
    /// (audit NET-205).
    func removeAll() {
        lock.lock()
        pins = [:]
        refusals = [:]
        lock.unlock()
        storage.savePins([:])
    }

    func noteRefused(_ fingerprint: String, forHost host: String) {
        lock.lock()
        refusals[host] = fingerprint
        lock.unlock()
    }

    func refusedFingerprint(forHost host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return refusals[host]
    }
}

/// What to do with one server-trust challenge.
nonisolated enum ServerTrustDecision: Equatable {
    /// The certificate is the one this host was pinned to, so it is accepted regardless of what the
    /// system's chain validation makes of it.
    case useCredential
    /// Left to the system. A host with a real certificate keeps working exactly as before, and one
    /// without keeps failing exactly as before, which is the failure the trust sheet reads.
    case defaultHandling
}

/// The single answer every session this app owns gives to a server-trust challenge.
///
/// Attached to `HTTPClient`'s sessions, the route resolver's probe, the artwork fetch and the
/// sidecar subtitle fetch. `EngineTLS.serverTrustEvaluator` reads the same store from the same
/// fingerprint, so the app and the engine cannot disagree about one origin.
nonisolated final class ServerTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// The one instance every session attaches to.
    ///
    /// Process-wide rather than container-owned because `HTTPClient()` is a default argument of
    /// `DependencyContainer.init`, so the first session exists before the container's body runs and
    /// could not be handed a delegate the container built. Consumers still read the store through
    /// `DependencyContainer.serverTrustStore`.
    static let shared = ServerTrustDelegate(
        store: ServerTrustStore(storage: KeychainTrustPinStorage(keychain: KeychainService())))

    let store: ServerTrustStore

    init(store: ServerTrustStore) {
        self.store = store
    }

    /// The whole policy, taking the trust object rather than the challenge: `URLProtectionSpace`
    /// cannot be built carrying a `serverTrust`, so a decision reading it off the challenge could
    /// only ever be tested on the arm where there is none.
    static func decide(
        host: String,
        port: Int,
        authenticationMethod: String,
        serverTrust: SecTrust?,
        store: ServerTrustStore
    ) -> ServerTrustDecision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust,
              let offered = CertificateFingerprint.sha256(ofLeafIn: serverTrust)
        else { return .defaultHandling }

        let key = ServerTrustStore.hostKey(host: host, port: port)
        guard store.pinnedFingerprint(forHost: key) == offered else {
            // Remembered, not accepted. The sheet needs a fingerprint to show, and a host whose
            // certificate has changed has to be able to say which one it is offering now.
            store.noteRefused(offered, forHost: key)
            return .defaultHandling
        }
        return .useCredential
    }

    /// Guards the diagnostic line above. Returns true when this host has not said this before.
    private func noteIfChanged(_ line: String, forHost host: String) -> Bool {
        logLock.lock(); defer { logLock.unlock() }
        guard lastLoggedLine[host] != line else { return false }
        lastLoggedLine[host] = line
        return true
    }
    private let logLock = NSLock()
    private var lastLoggedLine: [String: String] = [:]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let decision = Self.decide(
            host: space.host, port: space.port,
            authenticationMethod: space.authenticationMethod,
            serverTrust: space.serverTrust, store: store)
        // One line per server-trust challenge, because without it the only evidence of a decision is
        // whether the next request worked, and "the fingerprint did not match" and "the host key was
        // not the one that was pinned" look identical from there. The fingerprint is printed whole
        // so it can be held against what the server's own tooling prints.
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let key = ServerTrustStore.hostKey(host: space.host, port: space.port)
            let offered = space.serverTrust.flatMap(CertificateFingerprint.sha256(ofLeafIn:))
            let line = "[trust] \(key) offered \(offered ?? "no certificate") "
                + "pinned \(store.pinnedFingerprint(forHost: key) ?? "nothing") "
                + "-> \(decision == .useCredential ? "accepted" : "system decides")"
            // Once per host, and again whenever the answer changes. A challenge is raised per
            // connection, so browsing one library screen produced twenty identical lines on the
            // first device round and pushed everything else out of a 300-line buffer. What is worth
            // reading is the first answer for a host and every later one that differs from it.
            if noteIfChanged(line, forHost: key) { LogTap.shared.note(line) }
        }
        switch decision {
        case .useCredential:
            guard let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .defaultHandling:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Redirects

/// Which credentials a redirect may carry, for every session this delegate is attached to.
///
/// URLSession follows a redirect with the caller's headers, and on this CFNetwork only `Authorization`
/// is dropped across origins: `X-Emby-Token` (artwork) and Seerr's `Cookie: connect.sid` were
/// measured arriving at a different host, and an https to http hop sends them in cleartext (audit
/// NETWORK-3). The rule is the engine's `RedirectHeaderPolicy`: credentials only to the same host
/// with no TLS downgrade, where a same-host http to https upgrade counts, and there they are put back
/// on even when URLSession stripped them, so an `http://` address behind an upgrading proxy keeps
/// its login (NETWORK-4).
nonisolated enum RedirectPolicy {

    static let credentialHeaders = [
        "Authorization", "Cookie", "X-Emby-Token", "X-Emby-Authorization", "X-MediaBrowser-Token",
    ]

    /// Query items Jellyfin reads a token from. Artwork, subtitles, trickplay and downloads carry
    /// the token there instead of in a header.
    static let credentialQueryItems: Set<String> = ["api_key", "apikey", "x-emby-token"]

    /// Why a hop is refused.
    enum Refusal: Equatable {
        case downgrade
        /// The next URL would still carry the token after the items that hold it are dropped, for
        /// example a forward-auth SSO page that wraps the whole URL in `?rd=` (audit NET-209).
        case tokenInURL
    }

    enum Decision: Equatable {
        /// `leftURLTokenBehind`: the previous URL carried a token in its query that this hop does
        /// not take along.
        case follow(URLRequest, leftURLTokenBehind: Bool)
        case refuse(Refusal)
    }

    /// The one place a redirect is judged; `refusal` and `redirect` read from it.
    ///
    /// A hop to another origin loses the credential headers and every query item whose value is
    /// the token, and is followed. Refusing it outright (1.1.0 build 13) blanked every poster on a
    /// server whose artwork answers with a redirect to an image host (Sodalite#249). Jellyfin's
    /// image endpoints need no token, so the image host still answers.
    static func decide(_ proposed: URLRequest, from previous: URLRequest?) -> Decision {
        guard let previous, let from = previous.url, let to = proposed.url else {
            return .follow(proposed, leftURLTokenBehind: false)
        }
        if from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "http" { return .refuse(.downgrade) }

        var request = proposed
        if credentialsAllowed(from: from, to: to) {
            for name in credentialHeaders {
                if let value = previous.value(forHTTPHeaderField: name) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            return .follow(request, leftURLTokenBehind: false)
        }

        for name in credentialHeaders { request.setValue(nil, forHTTPHeaderField: name) }
        let urlTokens = queryCredentials(from)
        let tokens = urlTokens.union(headerCredentials(previous))
        guard !tokens.isEmpty else { return .follow(request, leftURLTokenBehind: false) }
        let stripped = removingQueryItems(valued: tokens, from: to)
        if contains(tokens, in: stripped) { return .refuse(.tokenInURL) }
        request.url = stripped
        return .follow(request, leftURLTokenBehind: !urlTokens.isEmpty)
    }

    static func refusal(_ proposed: URLRequest, from previous: URLRequest?) -> Refusal? {
        if case .refuse(let reason) = decide(proposed, from: previous) { return reason }
        return nil
    }

    /// The request to follow, or nil to refuse the hop (the 3xx is then the response).
    static func redirect(_ proposed: URLRequest, from previous: URLRequest?) -> URLRequest? {
        if case .follow(let request, _) = decide(proposed, from: previous) { return request }
        return nil
    }

    /// The token values the URL carries in a query item Jellyfin reads one from, lowercased
    /// (Jellyfin compares tokens without case).
    static func queryCredentials(_ url: URL) -> Set<String> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Set(items.compactMap { item in
            guard credentialQueryItems.contains(item.name.lowercased()),
                  let value = item.value, !value.isEmpty else { return nil }
            return value.lowercased()
        })
    }

    /// Tokens and cookie values the request sends in headers, lowercased. A proxy that copies one
    /// into the Location would otherwise hand it to the other host in the URL.
    static func headerCredentials(_ request: URLRequest) -> Set<String> {
        var tokens = Set<String>()
        for name in ["X-Emby-Token", "X-MediaBrowser-Token"] {
            if let value = request.value(forHTTPHeaderField: name), !value.isEmpty { tokens.insert(value.lowercased()) }
        }
        for name in ["Authorization", "X-Emby-Authorization"] {
            guard let value = request.value(forHTTPHeaderField: name),
                  let range = value.range(of: #"Token="([^"]+)""#, options: .regularExpression) else { continue }
            tokens.insert(value[range].dropFirst(7).dropLast().lowercased())
        }
        // Only long cookie values, so a short flag cannot match some unrelated part of the URL.
        for pair in (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 16 {
                tokens.insert((value.removingPercentEncoding ?? value).lowercased())
            }
        }
        return tokens
    }

    /// Drops every query item whose value is one of the tokens, whatever its name, and keeps the
    /// rest byte for byte: a presigned CDN URL breaks when its signature is encoded differently.
    static func removingQueryItems(valued tokens: Set<String>, from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else { return url }
        let kept = items.filter { item in
            !tokens.contains((item.value.flatMap { $0.removingPercentEncoding ?? $0 } ?? "").lowercased())
        }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// A token anywhere in the URL, in any case: also percent-encoded inside another parameter
    /// (`?rd=`, up to three layers) or base64 in one (an SSO `state`).
    static func contains(_ tokens: Set<String>, in url: URL) -> Bool {
        var text = url.absoluteString
        for _ in 0..<4 {
            if matches(tokens, text) { return true }
            if base64Values(in: text).contains(where: { matches(tokens, $0) }) { return true }
            guard let decoded = text.removingPercentEncoding, decoded != text else { return false }
            text = decoded
        }
        return false
    }

    private static func matches(_ tokens: Set<String>, _ text: String) -> Bool {
        let lowered = text.lowercased()
        return tokens.contains { lowered.contains($0) }
    }

    /// Every run of base64 or base64url characters long enough to hold a token, decoded, plus a
    /// percent-decoded copy of each. `=` ends a run (it is the separator in `state=`, the padding
    /// is put back), and a run with a `/` is tried whole and piece by piece, since the path's own
    /// slashes join it to its neighbours.
    private static func base64Values(in text: String) -> [String] {
        let runs = text.split { !($0.isASCII && ($0.isLetter || $0.isNumber || "+/-_".contains($0))) }
        let candidates = runs.flatMap { run in [run] + (run.contains("/") ? run.split(separator: "/") : []) }
        return candidates.filter { $0.count >= 24 }.flatMap { run -> [String] in
            var b64 = run.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
            guard let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8) else { return [] }
            return [decoded, decoded.removingPercentEncoding ?? decoded]
        }
    }

    /// Same host, and either the same scheme and port or an http to https upgrade.
    static func credentialsAllowed(from original: URL, to redirect: URL) -> Bool {
        guard let fromHost = original.host?.lowercased(), let toHost = redirect.host?.lowercased(),
              fromHost == toHost,
              let fromScheme = original.scheme?.lowercased(), let toScheme = redirect.scheme?.lowercased()
        else { return false }
        if fromScheme == toScheme {
            return effectivePort(original, scheme: fromScheme) == effectivePort(redirect, scheme: toScheme)
        }
        return fromScheme == "http" && toScheme == "https"
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "https" ? 443 : 80)
    }
}

extension ServerTrustDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let previous = task.currentRequest ?? task.originalRequest
        let fromHost = previous?.url?.host() ?? "?", toHost = request.url?.host() ?? "?"
        switch RedirectPolicy.decide(request, from: previous) {
        case .refuse(.downgrade):
            LogTap.shared.note("[http] refused a redirect from https to http at \(toHost)")
            completionHandler(nil)
        case .refuse(.tokenInURL):
            LogTap.shared.note("[http] refused to carry a token in the URL from \(fromHost) to \(toHost)")
            completionHandler(nil)
        case .follow(let followed, let leftURLTokenBehind):
            if leftURLTokenBehind, Self.shouldLogDroppedToken("\(fromHost) to \(toHost)") {
                LogTap.shared.note("[http] followed a redirect from \(fromHost) to \(toHost) without the URL token")
            }
            completionHandler(followed)
        }
    }

    /// Every poster on such a server takes the same hop, so the line comes once a minute per host
    /// pair: often enough to still be in the 300-line log when someone looks.
    private static func shouldLogDroppedToken(_ pair: String) -> Bool {
        let now = ContinuousClock.now
        return droppedTokenHops.withLock { last in
            if let previous = last[pair], now - previous < .seconds(60) { return false }
            last[pair] = now
            return true
        }
    }

    private static let droppedTokenHops = Mutex<[String: ContinuousClock.Instant]>([:])
}

/// The keychain half of the pin store.
///
/// It lives beside the store rather than in `DependencyContainer` for one reason: `HTTPClient()` is
/// a default argument of the container's own init, so it is constructed BEFORE the container's body
/// runs and cannot be handed anything the container built. The container still owns the handle every
/// consumer reads (`serverTrustStore`), so nothing else in the app reaches the keychain for this.
nonisolated struct KeychainTrustPinStorage: TrustPinStorage {

    private let keychain: any KeychainServiceProtocol

    init(keychain: any KeychainServiceProtocol) {
        self.keychain = keychain
    }

    func loadPins() -> [String: String] {
        guard let data = try? keychain.loadData(for: KeychainKeys.trustedCertificates) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func savePins(_ pins: [String: String]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? keychain.save(data, for: KeychainKeys.trustedCertificates)
    }
}
