import Foundation

/// One HTTP response, built whole before a byte goes out.
///
/// The body is `Data` rather than `String` because `Content-Length` counts bytes: a single umlaut in a
/// file name would otherwise make a character count a truncated response that the browser waits out.
nonisolated struct LogExportResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
    /// Sent after `body` by the server, straight from the descriptor, rather than copied into it: the
    /// persisted log runs to 32 MB and would otherwise sit in memory twice per request.
    var file: PersistedLogFile? = nil
    /// Set, the browser saves the response under this name instead of rendering it.
    var downloadName: String? = nil

    /// Status line, headers, blank line, body, and then the bytes of `file` if there is one, which
    /// `Content-Length` already counts. `Connection: close` because each request is answered once and
    /// the server has no reason to hold a socket open for a reader who has the text already.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count + (file?.length ?? 0))\r\n"
        if let downloadName {
            head += "Content-Disposition: attachment; filename=\"\(downloadName)\"\r\n"
        }
        // An expired link that a browser answers from its own cache would read as a live one.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func html(_ status: Int, _ reason: String, _ markup: String) -> LogExportResponse {
        LogExportResponse(
            status: status,
            reason: reason,
            contentType: "text/html; charset=utf-8",
            body: Data(markup.utf8)
        )
    }

    static func text(_ status: Int, _ reason: String, _ text: String) -> LogExportResponse {
        LogExportResponse(
            status: status,
            reason: reason,
            contentType: "text/plain; charset=utf-8",
            body: Data(text.utf8)
        )
    }
}

/// Everything about a log export that is not a socket: what is being served, to which path, and for
/// how long (Sodalite#148).
///
/// The lines are copied in at construction and never read again. The buffer keeps filling while the
/// reporter reads the page on a phone, and serving a moving target would mean the text they paste is
/// not the text they were looking at. It also keeps this type `Sendable`, so the connection handler on
/// the socket queue can hold it without touching the main actor.
///
/// No redaction happens here. `LogTap.note(_:)` is the single door every line comes through and
/// `LogRedaction` sits on it, so the buffer is already clean; a second pass here would be a second
/// place to forget.
nonisolated struct LogExportSession: Sendable {

    /// The provenance stamped on the document. Injected rather than read from the process, so the tests
    /// pin a fixed header and the header does not depend on which device ran them.
    struct Environment: Sendable {
        var appVersion: String
        var build: String
        var systemName: String
        var systemVersion: String
        var hardware: String

        /// Deliberately not `UIDevice`: that is main-actor isolated, and this is built on whichever
        /// thread opened the export. `ProcessInfo` and `uname` answer the same questions off it.
        static var current: Environment {
            var info = utsname()
            uname(&info)
            let hardware = withUnsafeBytes(of: &info.machine) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let version = ProcessInfo.processInfo.operatingSystemVersion
            var systemVersion = "\(version.majorVersion).\(version.minorVersion)"
            if version.patchVersion > 0 {
                systemVersion += ".\(version.patchVersion)"
            }
            #if os(tvOS)
            let systemName = "tvOS"
            #elseif os(macOS)
            let systemName = "macOS"
            #else
            let systemName = "iOS"
            #endif
            return Environment(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                systemName: systemName,
                systemVersion: systemVersion,
                hardware: hardware.isEmpty ? "?" : hardware
            )
        }
    }

    /// 64 bits of it. The only thing between the log and everyone else on the network, and a port in
    /// the ephemeral range is a short enough list to walk.
    ///
    /// 64 and not 128 because the address under the QR code is the documented fallback for a camera
    /// that will not focus on a television, so it has to fit on one line at a size that reads from a
    /// sofa: 16 hex characters instead of 32 take the whole URL from about 56 characters to 41. What
    /// that costs is nothing anyone can spend. Guessing this needs 2^63 requests against a socket that
    /// closes after five minutes, and the door it opens is a log that has already had its credentials
    /// stripped.
    let token: String
    let environment: Environment
    let capturedAt: Date
    let lifetime: TimeInterval

    private let lines: [String]
    /// The file sink's file as it stood when the export opened (AE#597), nil when the sink is off or
    /// never wrote. The buffer above is this launch only; this is what reaches back across restarts.
    let persistedLog: PersistedLogFile?

    /// Two names because they are two different files, and a reporter who downloads the one after
    /// reading the other must be able to tell them apart (Sodalite#164: both used to arrive as
    /// `sodalite-log.txt`, and the one the page offered to download was not the one it showed).
    static let persistedLogName = "sodalite-persistent-log.txt"
    static let sessionLogName = "sodalite-session-log.txt"

    var expiresAt: Date { capturedAt.addingTimeInterval(lifetime) }

    init(
        lines: [String],
        environment: Environment = .current,
        capturedAt: Date = Date(),
        lifetime: TimeInterval = 300,
        persistedLog: PersistedLogFile? = nil
    ) {
        self.lines = lines
        self.persistedLog = persistedLog
        self.environment = environment
        self.capturedAt = capturedAt
        self.lifetime = lifetime
        self.token = Self.makeToken()
    }

    /// Lowercase hex, because the URL underneath the QR code is also printed for anyone whose camera
    /// will not focus on a television, and mixed case is read wrong off a screen.
    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 8)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    // MARK: - What is handed over

    /// The plain text the reporter pastes into an issue: provenance, then the buffer.
    ///
    /// The header belongs to the DOCUMENT and not to the page chrome, so it survives both the copy
    /// button and a saved `log.txt`. Every report that arrives without a version and an OS costs a
    /// round trip to ask for them, and the reporter is the one person who cannot look them up later.
    /// English and unlocalized on purpose: this is evidence that gets diffed and pasted next to the log
    /// lines, which are English themselves.
    var document: String {
        let header = """
        Sodalite \(environment.appVersion) (\(environment.build)) - \
        \(environment.systemName) \(environment.systemVersion) - \(environment.hardware)
        \(lines.count) lines captured \(LogTimestamp.stamp(capturedAt))
        """
        guard !lines.isEmpty else { return header }
        return header + "\n\n" + lines.joined(separator: "\n")
    }

    /// Leads the downloaded file for the same reason `document` has a header, and says what the file is,
    /// because unlike the buffer it spans launches: every launch in it starts with a `file sink armed`
    /// line.
    var persistedLogHeader: String? {
        guard let persistedLog else { return nil }
        return """
        Sodalite \(environment.appVersion) (\(environment.build)) - \
        \(environment.systemName) \(environment.systemVersion) - \(environment.hardware)
        Persistent log, \(persistedLog.length) bytes, captured \(LogTimestamp.stamp(capturedAt))
        """
    }

    // MARK: - Serving

    private enum Route {
        case page
        case text
        case download
        case file
    }

    func response(to request: String, now: Date = Date()) -> LogExportResponse {
        guard let line = Self.requestLine(of: request) else {
            return .text(400, "Bad Request", "Bad Request")
        }
        guard let route = route(for: line.path) else {
            return .text(404, "Not Found", "Not Found")
        }
        guard line.method == "GET" else {
            return .text(405, "Method Not Allowed", "Method Not Allowed")
        }
        guard now < expiresAt else {
            return .html(410, "Gone", LogExportPage.expired())
        }

        switch route {
        case .page:
            let file = persistedLog.map { (path: "/\(token)/\(Self.persistedLogName)", length: $0.length) }
            return .html(200, "OK", LogExportPage.render(
                document: document,
                token: token,
                download: "/\(token)/\(Self.sessionLogName)",
                persistedLog: file
            ))
        case .text:
            return .text(200, "OK", document)
        case .download:
            var response = LogExportResponse.text(200, "OK", document)
            response.downloadName = Self.sessionLogName
            return response
        case .file:
            guard let persistedLog, let persistedLogHeader else {
                return .text(404, "Not Found", "Not Found")
            }
            var response = LogExportResponse.text(200, "OK", persistedLogHeader + "\n\n")
            response.file = persistedLog
            response.downloadName = Self.persistedLogName
            return response
        }
    }

    /// `GET /<token> HTTP/1.1`, and nothing else is looked at. The headers carry nothing this server
    /// acts on, so they are not parsed at all.
    ///
    /// `isNewline` and not a comparison against `"\r"` or `"\n"`: CRLF is ONE Swift Character, a grapheme
    /// cluster that equals neither of its halves. A request line cut on those two therefore never ends,
    /// the whole head arrives as one "line", and every valid request comes back a 400. Measured here on
    /// the first run of `LogExportSessionTests`, where 16 of 20 tests failed on it at once.
    private static func requestLine(of request: String) -> (method: String, path: Substring)? {
        let first = request.prefix { !$0.isNewline }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        // A reload adds a cache buster, a scanner may add a referrer parameter. Neither is a
        // different resource.
        return (String(parts[0]), parts[1].prefix { $0 != "?" })
    }

    /// Whole-string comparison, never a prefix: `/<token>evil` must not open the door.
    private func route(for path: Substring) -> Route? {
        switch path {
        case "/\(token)", "/\(token)/": .page
        case "/\(token)/log.txt": .text
        case "/\(token)/\(Self.sessionLogName)": .download
        case "/\(token)/\(Self.persistedLogName)": .file
        default: nil
        }
    }
}
