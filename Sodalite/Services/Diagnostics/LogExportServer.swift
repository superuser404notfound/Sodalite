import Foundation

/// Serves one `LogExportSession` to the local network for as long as it lives (Sodalite#148).
///
/// BSD sockets rather than `NWListener`, deliberately: AetherEngine's `HLSLocalServer` serves AVPlayer
/// and AirPlay receivers from an Apple TV this way in production, which makes binding `0.0.0.0` on tvOS
/// and being reached from another device a measured fact rather than a hope. The lifetime rules below
/// (`shutdown` before `close`, `SO_NOSIGPIPE` on every socket) are copied from it for the same reasons
/// its comments give.
///
/// Nothing here needs a Local Network entitlement: tvOS has no local network privacy at all, measured on
/// 26.6, so there is no permission to ask for and no prompt to design around.
///
/// One request per connection, no keep-alive: the reader has the text in the page after one response
/// and a held-open socket would only be a descriptor to leak.
nonisolated final class LogExportServer: @unchecked Sendable {

    /// The cases separate what goes in the log from what reaches a viewer. Which syscall refused, and
    /// with which errno, is the part that answers a bug report; the panel says the same actionable
    /// sentence for all of them, because none of them is a thing the person in front of the television
    /// can fix differently.
    enum StartError: LocalizedError {
        case socket(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case getsockname(errno: Int32)
        case noNetwork

        var errorDescription: String? {
            String(
                localized: "settings.log.export.failed.message",
                defaultValue: "The local page could not be started. Check that this Apple TV is connected to a network."
            )
        }
    }

    /// Everything the panel has to show: where to point a browser, and until when.
    struct Endpoint: Sendable {
        let url: URL
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "de.superuser404.sodalite.logexport.accept")
    private let workQueue = DispatchQueue(label: "de.superuser404.sodalite.logexport.work", attributes: .concurrent)
    /// The deadline gets a queue of its own. The accept queue is serial and its loop is parked inside a
    /// blocking `accept()` for the whole life of the export, so a timer scheduled there never runs and
    /// the link would outlive its own countdown. Caught by `expiresOnItsOwn`, not by reading the code.
    private let expiryQueue = DispatchQueue(label: "de.superuser404.sodalite.logexport.expiry")

    /// A browser opens a handful of connections for the page and the download. More than this at once
    /// is a peer holding workers, and the export only has to serve one person (audit DIAG-7).
    static let maximumConnections = 8
    /// How long a peer gets to send its whole request head, however it paces the bytes: the receive
    /// timeout alone restarts with every byte, so a slow drip held a worker without end.
    static let requestHeadDeadline: TimeInterval = 5
    /// Pause after an accept error that is not a plain retry.
    static let acceptBackoff: TimeInterval = 0.25

    private var listenFd: Int32 = -1
    private var clientFds = Set<Int32>()
    private var shouldStop = false
    private var session: LogExportSession?
    private var expiryTimer: DispatchSourceTimer?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFd >= 0
    }

    // MARK: - Lifetime

    /// Binds an ephemeral port, arms the deadline and returns the address to put under the QR code.
    /// `persistedLog` is the file sink's files, oldest first; they are frozen here, with the lines, and
    /// offered as one download when they hold anything.
    func start(lines: [String], persistedLog: [URL] = [], lifetime: TimeInterval = 300) throws -> Endpoint {
        stop()

        guard let address = Self.localAddress() else { throw StartError.noNetwork }

        let session = LogExportSession(
            lines: lines,
            lifetime: lifetime,
            persistedLog: PersistedLogFile(urls: persistedLog)
        )
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno: errno) }

        var on: Int32 = 1
        // A restarted export lands on a fresh ephemeral port, but the previous one may still be in
        // TIME_WAIT; SO_REUSEADDR keeps that from being the reason a retry fails.
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // Without SO_NOSIGPIPE a peer that closes mid-write kills the process instead of returning EPIPE.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        // All interfaces: the point is to be reached from a phone, and the device's own LAN address is
        // what goes in the URL.
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw StartError.bind(errno: error)
        }

        // One reader, maybe a second tab. 8 is already generous.
        guard Darwin.listen(fd, 8) == 0 else {
            let error = errno
            close(fd)
            throw StartError.listen(errno: error)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let error = errno
            close(fd)
            throw StartError.getsockname(errno: error)
        }
        let port = UInt16(bigEndian: actual.sin_port)

        guard let url = URL(string: "http://\(address):\(port)/\(session.token)") else {
            close(fd)
            throw StartError.noNetwork
        }

        lock.lock()
        listenFd = fd
        shouldStop = false
        self.session = session
        lock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        armExpiry(at: session.expiresAt)
        LogTap.shared.note(
            "[LogExport] serving \(session.token.prefix(4))… on \(address):\(port) for \(Int(lifetime))s,"
                + " persistent log \(session.persistedLog.map { "\($0.length) bytes" } ?? "none")"
        )

        return Endpoint(url: url, expiresAt: session.expiresAt)
    }

    func stop() {
        lock.lock()
        let wasRunning = listenFd >= 0
        shouldStop = true
        let fdToClose = listenFd
        listenFd = -1
        session = nil
        // shutdown() and NOT close() on the clients: their handler still owns the descriptor and closes
        // it itself. Under the lock, because the handler drops its fd from the set under the same lock
        // before closing it, so every number in the set is still that client's and not a reused one.
        for fd in clientFds {
            shutdown(fd, SHUT_RDWR)
        }
        clientFds.removeAll()
        expiryTimer?.cancel()
        expiryTimer = nil
        lock.unlock()

        // shutdown() before close() on the listen fd: close releases the number while the accept loop
        // may still hold it, and a later export could be handed the same one. shutdown() wakes the
        // blocked accept without releasing it.
        if fdToClose >= 0 {
            shutdown(fdToClose, SHUT_RDWR)
            close(fdToClose)
        }
        if wasRunning {
            LogTap.shared.note("[LogExport] stopped")
        }
    }

    deinit {
        stop()
    }

    /// The deadline is enforced by closing the listener, not only by the 410 branch in the session: a
    /// link that has run out should stop existing rather than stay open and answer.
    private func armExpiry(at deadline: Date) {
        let timer = DispatchSource.makeTimerSource(queue: expiryQueue)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            self?.stop()
        }
        lock.lock()
        expiryTimer = timer
        lock.unlock()
        timer.resume()
    }

    // MARK: - Accepting

    private func acceptLoop() {
        var consecutiveFailures = 0
        while true {
            lock.lock()
            let stopping = shouldStop
            let fd = listenFd
            lock.unlock()
            if stopping || fd < 0 { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLen)
                }
            }
            if clientFd < 0 {
                let error = errno
                // EBADF/EINVAL: the listener was closed by stop(). Anything else transient: retry, the
                // check at the top of the loop is what exits.
                if error == EBADF || error == EINVAL { return }
                if error == EINTR || error == EAGAIN || error == ECONNABORTED { continue }
                // EMFILE and ENFILE keep failing at once until a descriptor frees up, so without a pause
                // this loop spun a core and filled the log (audit PTD-206). Logged once per streak.
                consecutiveFailures += 1
                if consecutiveFailures == 1 {
                    LogTap.shared.note("[LogExport] accept failed errno=\(error), backing off")
                }
                Thread.sleep(forTimeInterval: Self.acceptBackoff)
                continue
            }
            consecutiveFailures = 0

            lock.lock()
            let full = clientFds.count >= Self.maximumConnections
            lock.unlock()
            if full {
                close(clientFd)
                continue
            }

            var on: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A connection that opens and then says nothing must not hold a worker forever.
            // The receive side only ever reads a request head, so it gets the shorter bound; the send
            // side streams the whole log to a slow browser.
            var receiveTimeout = timeval(tv_sec: 3, tv_usec: 0)
            var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

            lock.lock()
            clientFds.insert(clientFd)
            lock.unlock()

            workQueue.async { [weak self] in
                self?.handle(clientFd)
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer {
            lock.lock()
            clientFds.remove(fd)
            lock.unlock()
            close(fd)
        }

        lock.lock()
        let session = self.session
        lock.unlock()
        guard let session, let request = Self.readRequest(fd) else { return }

        let response = session.response(to: request)
        guard response.serialized.withUnsafeBytes({ Self.sendAll(fd, $0) }) else { return }
        response.file?.stream { Self.sendAll(fd, $0) }
    }

    private static func sendAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        var sent = 0
        while sent < buffer.count {
            let written = send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
            if written <= 0 { return false }
            sent += written
        }
        return true
    }

    /// Reads until the blank line that ends the request head, and no further: this server answers two
    /// GETs and there is no body to consume. Capped, so a peer that never sends the blank line cannot
    /// grow a buffer without end.
    private static func readRequest(_ fd: Int32) -> String? {
        let limit = 8 * 1024
        let deadline = Date().addingTimeInterval(requestHeadDeadline)
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)

        while buffer.count < limit {
            guard Date() < deadline else { return nil }
            let read = recv(fd, &chunk, chunk.count, 0)
            guard read > 0 else { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            buffer.append(contentsOf: chunk[0 ..< read])
            if Self.containsHeadTerminator(buffer) { break }
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func containsHeadTerminator(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        for index in 0 ... (bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10
            && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return true
        }
        return false
    }

    // MARK: - Where to point the browser

    /// The device's own LAN IPv4 address. `en*` only, so cellular (`pdp_ip*`), VPN (`utun*`) and AirDrop
    /// (`awdl*`) are out, with en0 preferred because that is WiFi on Apple hardware. Same shape as
    /// AetherEngine's, including its caveat: en0 is not always the active interface on a wired Apple TV,
    /// hence the fall back to the lowest numbered wired `en*`.
    static func localAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var byInterface: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                byInterface[name] = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
        }

        if let wifi = byInterface["en0"] { return wifi }
        return byInterface.keys.sorted().compactMap { byInterface[$0] }.first
    }
}
