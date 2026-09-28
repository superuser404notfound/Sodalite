import Foundation

/// The completion handler iOS hands over when it relaunches the app for background download events.
@MainActor
enum DownloadRelaunch {
    static var pendingCompletionHandler: (() -> Void)?
}

/// The one background session (Sodalite#81). Its callbacks run on the session's queue; the only work
/// done there is moving a finished file into the store before the callback returns (the system
/// deletes the temp file right after), everything else hops to the main actor.
nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "de.superuser404.Sodalite.downloads"
    let paths: DownloadPaths
    var onEvent: (@Sendable (DownloadEvent) -> Void)?
    var onFinishEvents: (@Sendable () -> Void)?
    /// Created in init: a relaunch for background events must reconnect before any event arrives.
    private(set) var session: URLSession!

    init(paths: DownloadPaths) {
        self.paths = paths
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
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
        onEvent?(.finished(tag, status: status, movedTo: moved))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = downloadTask.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) else { return }
        onEvent?(.progress(tag, written: totalBytesWritten, expected: max(totalBytesExpectedToWrite, 0)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let tag = task.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) else { return }
        let nsError = error as NSError
        onEvent?(.failed(tag, resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                         cancelled: nsError.code == NSURLErrorCancelled))
    }

    /// Same pinning store as every other request, so a self-signed server that was trusted once
    /// downloads like it streams.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ServerTrustDelegate.shared.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onFinishEvents?()
    }
}

/// `DownloadTransport` over the background session.
@MainActor
final class BackgroundDownloadTransport: DownloadTransport {
    private let delegate: DownloadSessionDelegate

    init(delegate: DownloadSessionDelegate) { self.delegate = delegate }

    func start(request: URLRequest, resumeData: Data?, tag: DownloadTaskTag, allowsCellular: Bool) -> Int {
        var request = request
        request.allowsCellularAccess = allowsCellular
        let task = resumeData.map { delegate.session.downloadTask(withResumeData: $0) } ?? delegate.session.downloadTask(with: request)
        task.taskDescription = tag.encoded
        task.resume()
        return task.taskIdentifier
    }

    func cancel(tag: DownloadTaskTag, producingResumeData: Bool) async -> Data? {
        let tasks = await delegate.session.allTasks
        guard let task = tasks.first(where: { $0.taskDescription == tag.encoded }) else { return nil }
        if producingResumeData, let download = task as? URLSessionDownloadTask {
            return await download.cancelByProducingResumeData()
        }
        task.cancel()
        return nil
    }

    func liveTags() async -> Set<DownloadTaskTag> {
        Set(await delegate.session.allTasks.compactMap { $0.taskDescription.flatMap(DownloadTaskTag.init(encoded:)) })
    }
}
