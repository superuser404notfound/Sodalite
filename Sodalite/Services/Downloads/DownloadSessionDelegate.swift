import Foundation

/// The completion handlers iOS hands over when it relaunches the app for background download
/// events, per session identifier. Either side can arrive first: the sessions exist from the
/// container's init, so a session may report it is done before the app delegate stored the handler.
@MainActor
enum DownloadRelaunch {
    private static var handlers: [String: () -> Void] = [:]
    private static var finished: Set<String> = []

    static func store(_ handler: @escaping () -> Void, for identifier: String) {
        if finished.remove(identifier) != nil { handler() } else { handlers[identifier] = handler }
    }

    static func sessionFinishedEvents(_ identifier: String) {
        if let handler = handlers.removeValue(forKey: identifier) { handler() } else { finished.insert(identifier) }
    }
}

/// Carries session events to whoever handles them, and holds the ones that arrive before a
/// handler is attached: a relaunched session starts delivering the moment it is created.
nonisolated final class DownloadEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (DownloadEvent) -> Void)?
    private var pending: [DownloadEvent] = []

    func attach(_ handler: @escaping @Sendable (DownloadEvent) -> Void) {
        let backlog: [DownloadEvent] = lock.withLock {
            self.handler = handler
            defer { pending = [] }
            return pending
        }
        backlog.forEach(handler)
    }

    func send(_ event: DownloadEvent) {
        let current: (@Sendable (DownloadEvent) -> Void)? = lock.withLock {
            if handler == nil { pending.append(event) }
            return handler
        }
        current?(event)
    }
}

/// The two background sessions (Sodalite#81), one allowed on cellular and one not: a task keeps the
/// network access it was created with, resume data included, so the Wi-Fi only switch is a choice of
/// session rather than a flag on a request. Callbacks run on the session queue; the only work done
/// there is moving a finished file into the store before the callback returns (the system deletes
/// the temp file right after), everything else goes through the relay to the main actor.
nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "de.superuser404.Sodalite.downloads"
    static let wifiIdentifier = "de.superuser404.Sodalite.downloads.wifi"
    static let identifiers: Set<String> = [identifier, wifiIdentifier]

    let paths: DownloadPaths
    let relay: DownloadEventRelay
    private let lock = NSLock()
    /// Last progress fraction and time sent per task, so a fast link does not flood the main actor.
    private var lastProgress: [Int: (fraction: Double, at: Date)] = [:]
    private(set) var cellularSession: URLSession!
    private(set) var wifiSession: URLSession!

    init(paths: DownloadPaths, relay: DownloadEventRelay) {
        self.paths = paths
        self.relay = relay
        super.init()
        cellularSession = makeSession(Self.identifier, allowsCellular: true)
        wifiSession = makeSession(Self.wifiIdentifier, allowsCellular: false)
    }

    private func makeSession(_ identifier: String, allowsCellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = allowsCellular
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = downloadTask.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var moved: URL?
        if (200..<300).contains(status) {
            let dir = paths.itemDirectory(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID)
            let target = dir.appendingPathComponent("media.\(tag.fileExtension)")
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.moveItem(at: location, to: target)) != nil { moved = target }
        }
        relay.send(.finished(tag, status: status, movedTo: moved))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = downloadTask.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) else { return }
        let expected = max(totalBytesExpectedToWrite, 0)
        let fraction = expected > 0 ? Double(totalBytesWritten) / Double(expected) : Double(totalBytesWritten)
        let now = Date()
        let due: Bool = lock.withLock {
            let last = lastProgress[downloadTask.taskIdentifier]
            // At most four a second; with no known length the byte count is the fraction, so the
            // time limit alone applies.
            guard last.map({ now.timeIntervalSince($0.at) >= 0.25 }) ?? true else { return false }
            lastProgress[downloadTask.taskIdentifier] = (fraction, now)
            return true
        }
        guard due else { return }
        relay.send(.progress(tag, written: totalBytesWritten, expected: expected))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { _ = lastProgress.removeValue(forKey: task.taskIdentifier) }
        guard let error, let tag = task.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) else { return }
        let nsError = error as NSError
        relay.send(.failed(tag, resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                           cancelled: nsError.code == NSURLErrorCancelled))
    }

    /// Same pinning store as every other request, so a self-signed server that was trusted once
    /// downloads like it streams.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ServerTrustDelegate.shared.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in DownloadRelaunch.sessionFinishedEvents(identifier) }
    }
}

/// `DownloadTransport` over the two background sessions.
@MainActor
final class BackgroundDownloadTransport: DownloadTransport {
    private let delegate: DownloadSessionDelegate

    init(delegate: DownloadSessionDelegate) { self.delegate = delegate }

    private var sessions: [URLSession] { [delegate.cellularSession, delegate.wifiSession] }

    func start(request: URLRequest, resumeData: Data?, tag: DownloadTaskTag, allowsCellular: Bool) -> Int {
        let session: URLSession = allowsCellular ? delegate.cellularSession : delegate.wifiSession
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        task.taskDescription = tag.encoded
        task.resume()
        return task.taskIdentifier
    }

    func cancel(tag: DownloadTaskTag, producingResumeData: Bool) async -> Data? {
        for session in sessions {
            let tasks = await session.allTasks
            guard let task = tasks.first(where: { $0.taskDescription == tag.encoded }) else { continue }
            if producingResumeData, let download = task as? URLSessionDownloadTask {
                return await download.cancelByProducingResumeData()
            }
            task.cancel()
            return nil
        }
        return nil
    }

    func liveTags() async -> Set<DownloadTaskTag> {
        var tags: Set<DownloadTaskTag> = []
        for session in sessions {
            tags.formUnion(await session.allTasks.compactMap { $0.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) })
        }
        return tags
    }

    func cancelAll(where matches: @escaping @Sendable (DownloadTaskTag) -> Bool) async {
        for session in sessions {
            for task in await session.allTasks {
                guard let tag = task.taskDescription.flatMap(DownloadTaskTag.init(encoded:)), matches(tag) else { continue }
                task.cancel()
            }
        }
    }
}
