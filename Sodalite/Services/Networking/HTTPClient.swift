import Foundation

protocol HTTPClientProtocol: Sendable {
    func request<T: Decodable>(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String],
        responseType: T.Type
    ) async throws -> T

    func request(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws

    func requestData(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse)
}

final class HTTPClient: HTTPClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Caps in-flight requests: unthrottled Home fan-out (60-90 reqs) trips a CDN/WAF in front of Jellyfin into tarpitting + timeout-nil rows (Sodalite#12/#14). 6 = browser-like per-host; per-client so Jellyfin/Seerr don't share a budget.
    private let inFlightLimiter = AsyncSemaphore(limit: 6)

    /// Optional per-request transport timing, already rendered to text. Only the discovery client
    /// sets it (see `HTTPClient.discovery()`); nil keeps the delegate out of every other request.
    private let transportTiming: (@Sendable (URL, String) -> Void)?

    /// Told whenever a request does not get served, so the app can re-measure a server verdict that
    /// may have gone stale (Sodalite#126).
    ///
    /// This is the only evidence that exists when a server dies on an UNCHANGED network. Every other
    /// re-probe trigger is an event about the DEVICE, a path change, a foreground, a server switch,
    /// and none of them fires when a NAS goes to sleep behind an Apple TV that never leaves its
    /// network, which is the only outage an Apple TV can have. Set by the composition root on the
    /// Jellyfin client alone; a Seerr timeout says nothing about which Jellyfin address answers.
    ///
    /// Two ways not to be served, and the second one produces no transport error to notice it by: a
    /// server that answers 5xx is refusing to serve, and behind a reverse proxy that stays up while
    /// the origin restarts it is the ONLY symptom there is.
    ///
    /// A cancelled request never reaches it: cancellation is answered above, and a request the app
    /// itself called off is not news about a server.
    nonisolated(unsafe) var onServerDidNotServe: (@Sendable () -> Void)?

    nonisolated init(
        session: URLSession? = nil,
        transportTiming: (@Sendable (URL, String) -> Void)? = nil
    ) {
        self.transportTiming = transportTiming
        // Cookies disabled: clients set auth manually (Seerr connect.sid, Jellyfin header). Auto-persisted cookies would reattach a stale connect.sid to the fresh /auth/jellyfin POST and earn a 401.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil

            // .reloadRevalidatingCacheData: conditional GET (If-None-Match) every request, so freshness == no-cache (server always authoritative) but unchanged metadata returns a 304 stub instead of multi-MB payload (Sodalite#12). 10MB mem (hot home rows) / 50MB disk (survives restart for cheap cold-launch revalidate). Images cache separately (AsyncCachedImage).
            config.urlCache = URLCache(
                memoryCapacity: 10 * 1024 * 1024,
                diskCapacity: 50 * 1024 * 1024,
                diskPath: "sodalite-http-cache"
            )
            config.requestCachePolicy = .reloadRevalidatingCacheData
            // Belt to inFlightLimiter: transport pool shouldn't exceed what the limiter admits.
            config.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: config)
        }

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func request<T: Decodable>(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String],
        responseType: T.Type
    ) async throws -> T {
        let (data, response) = try await requestData(baseURL: baseURL, endpoint: endpoint, headers: headers)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if let url = response.url {
                LogTap.shared.note(
                    HTTPDiagnostics.decode(method: endpoint.method.rawValue, url: url, type: T.self, error: error)
                )
            }
            throw APIError.decodingError(error)
        }
    }

    func request(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws {
        let _ = try await requestData(baseURL: baseURL, endpoint: endpoint, headers: headers)
    }

    func requestData(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try buildRequest(baseURL: baseURL, endpoint: endpoint, headers: headers)

        // wait() suspends without starting the request's timeout clock; permit balanced by the defer below on every exit path.
        try await inFlightLimiter.wait()
        defer { inFlightLimiter.signal() }

        let data: Data
        let response: URLResponse
        do {
            if let transportTiming {
                let requestURL = urlRequest.url ?? baseURL
                (data, response) = try await session.data(
                    for: urlRequest,
                    delegate: TransportTimingDelegate(url: requestURL, sink: transportTiming)
                )
            } else {
                (data, response) = try await session.data(for: urlRequest)
            }
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces task cancellation as URLError(.cancelled); rethrow as CancellationError so callers ignore it instead of painting "Network connection failed".
            throw CancellationError()
        } catch let error as CancellationError {
            throw error
        } catch {
            if let url = urlRequest.url {
                LogTap.shared.note(
                    HTTPDiagnostics.transport(method: endpoint.method.rawValue, url: url, error: error)
                )
            }
            onServerDidNotServe?()
            throw await Self.transportFailure(error, url: urlRequest.url)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            #if os(iOS)
            // Evidence that this app is reaching something, which is what keeps a denial measured on
            // one address from covering a session another address is serving fine (Sodalite#92).
            LocalNetworkAccess.noteReachableServer()
            #endif
            return (data, httpResponse)
        default:
            if (500...599).contains(httpResponse.statusCode) { onServerDidNotServe?() }
            if let url = httpResponse.url {
                LogTap.shared.note(
                    HTTPDiagnostics.status(
                        method: endpoint.method.rawValue,
                        url: url,
                        statusCode: httpResponse.statusCode,
                        body: data
                    )
                )
            }
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized(message: APIError.extractErrorMessage(from: data))
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    /// The `APIError` a transport failure maps to. Cancellation never reaches here: it is answered
    /// above, before the failure log, because a cancelled request is not a failure to report.
    ///
    /// A denied Local Network permission is checked before the code table, because it arrives
    /// wearing `.notConnectedToInternet` and would otherwise be filed as an unreachable server
    /// (Sodalite#92). The pre-filter runs first so the probe costs nothing on the ordinary failures:
    /// only a LAN address that failed with that exact sentence gets as far as asking the system.
    private static func transportFailure(_ error: Error, url: URL?) async -> APIError {
        guard let urlError = error as? URLError else { return .networkError(error) }
        #if os(iOS)
        if let url, LocalNetworkAccess.couldBeDenial(urlError, url: url),
           await LocalNetworkAccess.isDenied(for: url) {
            return .localNetworkDenied
        }
        #endif
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .cannotConnectToHost:
            return .serverUnreachable
        default:
            return .networkError(error)
        }
    }

    private func buildRequest(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) throws -> URLRequest {
        var components: URLComponents?
        if let encodedPath = endpoint.percentEncodedPath {
            components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
            let basePath = baseURL.path
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            components?.percentEncodedPath = trimmedBase + encodedPath
        } else {
            components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: true)
        }
        components?.queryItems = endpoint.queryItems
        // URLComponents leaves "+" literal, but ASP.NET (Jellyfin) / Express (Seerr) decode it as space ("Disney+"→"Disney "). Spaces are already %20 here, so any remaining "+" is a real plus, escape to %2B.
        let encodedQuery = components?.percentEncodedQuery
        components?.percentEncodedQuery = encodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        guard let url = components?.url, !Self.navigatesUpward(url) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Endpoints may override the 30s default (e.g. fire-and-forget session-progress writes surviving a slow CDN hiccup, Sodalite#12).
        request.timeoutInterval = endpoint.timeoutInterval ?? 30

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = endpoint.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        return request
    }

    /// Does this path still contain a `.` or `..` segment the server would resolve away?
    ///
    /// Every endpoint path in this app is a literal with ids interpolated into it, so a navigating
    /// segment can only have arrived inside one of those ids, and it retargets the request while the
    /// auth header rides along unchanged. Checked at the funnel rather than at each endpoint, so an
    /// endpoint written tomorrow is covered without anyone remembering this.
    ///
    /// `standardized` is what resolves those segments, so the comparison asks the same question the
    /// server will. Trailing slashes, empty paths and `//` are left alone by it, which is why this
    /// does not fire on the legitimate shapes.
    static func navigatesUpward(_ url: URL) -> Bool {
        url.standardized.path != url.path
    }
}

extension HTTPClient {
    /// Client for server-discovery probes.
    ///
    /// Its own ephemeral session, for three reasons. A probe the user is watching a spinner for must
    /// not queue behind the app's own traffic on a shared in-flight budget. A reachability answer
    /// must come off the wire, never out of the shared response cache. And the transport timing
    /// below belongs on discovery only: stamping a timing line on every Jellyfin and Seerr request
    /// would bury the diagnostic log it exists for.
    nonisolated static func discovery() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        return HTTPClient(
            session: URLSession(configuration: config),
            transportTiming: { url, timing in
                LogTap.shared.note("[discovery] timing \(url.absoluteString) -> \(timing)")
            }
        )
    }
}

/// Per-task delegate that renders `URLSessionTaskMetrics` into one line and hands it on.
///
/// It exists for the probe that ran into its cap: measured on macOS 26, metrics are still delivered
/// for a CANCELLED task, and they separate the two failures a discovery log could not tell apart.
/// A dropped SYN (a router refusing traffic from outside) stamps no phase at all, while a host that
/// accepted the connection and then said nothing stamps name lookup and connect and leaves the first
/// byte unfinished. Without this the cap could only report that ten seconds had passed.
///
/// The metrics object is not Sendable, so it is rendered here, on the delegate's own queue, and only
/// the text crosses over.
private nonisolated final class TransportTimingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let url: URL
    private let sink: @Sendable (URL, String) -> Void

    init(url: URL, sink: @escaping @Sendable (URL, String) -> Void) {
        self.url = url
        self.sink = sink
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        sink(url, Self.describe(metrics))
    }

    private static func describe(_ metrics: URLSessionTaskMetrics) -> String {
        let total = String(format: "%.1fs", metrics.taskInterval.duration)
        guard let transaction = metrics.transactionMetrics.last else {
            return "total \(total), no transaction"
        }
        func phase(_ start: Date?, _ end: Date?) -> String {
            guard let start else { return "none" }
            guard let end else { return "unfinished" }
            return String(format: "%.2fs", end.timeIntervalSince(start))
        }
        let dns = phase(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        let connect = phase(transaction.connectStartDate, transaction.connectEndDate)
        let tls = phase(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        let firstByte = phase(transaction.requestStartDate, transaction.responseStartDate)
        return "total \(total), dns \(dns), connect \(connect), tls \(tls), first byte \(firstByte)"
    }
}

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        _encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
