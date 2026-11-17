import AetherEngine
import Foundation
import Combine
import StoreKit

/// Ring buffer of diagnostic log lines for Settings > Diagnostic Log so a tester with no Mac can read and screenshot them. Every line is stored with a fixed-width UTC stamp already in front of it, so the screenshot, the iOS Copy output and the console mirror cannot disagree about when something happened. Lines arrive via `AetherEngine.EngineLog.handler` (engine) and direct `note(_:)` (host). Does NOT redirect stdout via dup2: unreliable on tvOS Release (stdout null-redirected with no debugger). Type is MainActor-isolated for the `lines` publisher; `note(_:)`/`clear()` are explicitly `nonisolated` because the engine calls them off its own threads (the compiler now enforces what was previously safe only by accident).
final class LogTap: ObservableObject {

    nonisolated static let shared = LogTap()

    /// Mirror every line to the console as well? On for DEBUG + sandbox (TestFlight), off for App Store. Engine lines reach the buffer on EVERY build (see SodaliteApp), so this no longer gates what Settings > Diagnostic Log can show. Sandbox detection mirrors `StoreKitService.isSupporter`: authoritative answer is async `AppTransaction` (receipt-URL deprecated tvOS 18) but this flag is read synchronously in `SodaliteApp.init`, so read a UserDefaults cache and let `refreshDiagnosticBuildFlag()` overwrite per launch (first TestFlight launch = off, every later launch = on).
    nonisolated static let isDiagnosticBuild: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: sandboxBuildCacheKey)
        #endif
    }()

    private nonisolated static let sandboxBuildCacheKey = "logTap.cachedIsSandboxBuild"

    /// Re-derive the cached sandbox flag from StoreKit 2; effective next launch (isDiagnosticBuild is a per-launch snapshot). Leaves the cache untouched on unverified transaction (offline) so a transient failure doesn't lose a true flag.
    nonisolated static func refreshDiagnosticBuildFlag() async {
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return }
        UserDefaults.standard.set(
            transaction.environment == .sandbox,
            forKey: sandboxBuildCacheKey
        )
    }

    /// The build these lines came out of, as one line. The engine number is the one a reader cannot
    /// reconstruct afterwards, because SwiftPM pins a revision rather than a tag, and a log analysed
    /// without it gets the version supplied from an older thread (AetherPlayer#7). It is noted at
    /// launch and prepended to every way the log leaves the device, because the buffer is 300 lines
    /// and a long session rolls the noted copy off the top.
    nonisolated static var environmentLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Sodalite \(version) (\(build)) | AetherEngine \(AetherEngine.version)"
            + " | \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    @Published private(set) var lines: [String] = []

    /// Count of every line ever appended, never reset except by `clear()`. `lines.count` pins at
    /// `maxLines` once the ring starts evicting from the front, so a view keyed on it (row identity,
    /// `onChange`) stops noticing new lines arrive at all (Audit 2026-09-25 DIAG-8). This keeps
    /// climbing regardless, and a line's id derived from it (`sequenceNumber` minus its distance from
    /// the end) stays stable across both plain growth and eviction: see DiagnosticLogView.
    @Published private(set) var sequenceNumber = 0

    // 300: holds a full HLS-wrapper session start (init.mp4 dump + m3u8 bodies + per-request logs) through the eventual AVPlayer failure; the previous 80 rolled the init.mp4 summary off before the failure landed.
    private let maxLines = 300

    /// Internal, not private, so a test can own a buffer that nothing else in the process writes into.
    nonisolated init() {}

    /// Append one line to the buffer. Safe to call from any thread.
    ///
    /// The single door every line comes through, host and engine alike, which is why credential
    /// stripping and the UTC stamp both sit here and not at the call sites (see LogRedaction,
    /// LogTimestamp). The stamp is taken first, before any work on the line, so it dates the moment the
    /// line was emitted rather than the moment it reached the buffer: `note` hops to the main actor to
    /// append, and two threads that hop in the same instant can land in either order. Reading a stamp
    /// out of order is then a true statement about a race, where an append-time stamp would have hidden
    /// it. An engine line is dated just as honestly, because `EngineLog` calls its handler synchronously
    /// on the thread that emitted it.
    nonisolated func note(_ line: String) {
        let stamp = LogTimestamp.stamp()
        // Stamp AFTER redaction, so the redactor never scans the stamp and the offsets it reports (were
        // it ever to report any) stay offsets into the line its author wrote.
        let line = "\(stamp)  \(LogRedaction.redact(line))"
        // Mirror to console on diagnostic builds so host notes appear in an Xcode/Console capture alongside engine prints.
        if Self.isDiagnosticBuild {
            print(line)
        }
        if Self.fileSinkEnabled {
            appendToFile(line)
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lines.append(line)
                self.sequenceNumber += 1
                if self.lines.count > self.maxLines {
                    self.lines.removeFirst(self.lines.count - self.maxLines)
                }
            }
        }
    }

    /// A measurement that outlives the app.
    ///
    /// The buffer above is 300 lines in memory, wiped on every launch, which is the right shape for
    /// "what went wrong just now" and the wrong one for a test that runs for ten minutes or that ends
    /// with the app being terminated in the background. A twelve minute pause on a live channel is
    /// both: measured on a device, the session that was meant to produce the evidence came back with
    /// nothing in it but the next launch.
    ///
    /// AE#597: it used to be debug-only, which made the one class of bug that needs it the one class
    /// it could not be used on. A wake-from-sleep failure puts an hour between the cause and the
    /// symptom and ends with a reboot, so a TestFlight capture came back holding 300 lines of
    /// aftermath and nothing of the transition. It is now a switch anybody can turn on, off by
    /// default, and every line has already been through `LogRedaction` by the time it gets here.
    ///
    /// Capped so a long session cannot fill the container, as two halves: when the live file reaches
    /// `fileSegmentBytes` it becomes `sodalite-log.1.txt` (replacing the previous one) and a fresh file
    /// starts. A single capped file had to stop writing when full, which dropped the NEWEST lines, the
    /// ones next to the symptom; rotating drops the oldest instead. `Library/Caches` because tvOS forbids app
    /// writes to `Documents` and the failure there is a swallowed throw, which reads exactly like
    /// "the app produced no logs". Pull it with:
    ///
    ///     xcrun devicectl device copy from --device <uuid> \
    ///       --domain-type appDataContainer --domain-identifier de.superuser404.Sodalite \
    ///       --user mobile --source Library/Caches/sodalite-log.txt --destination pulled.txt
    private nonisolated static let fileQueue =
        DispatchQueue(label: "de.superuser404.sodalite.logfile")
    nonisolated static let fileCapBytes = 32 * 1024 * 1024
    nonisolated static let fileSegmentBytes = fileCapBytes / 2

    /// Read once per line on the emitting thread, so it is a cached flag rather than a defaults
    /// read: `note(_:)` runs several times a second on a live session. Written at launch and when
    /// the switch is flipped.
    nonisolated(unsafe) static var fileSinkEnabled = false
    nonisolated static let fileSinkDefaultsKey = "diagnostics.persistentLog"

    /// Owned here rather than by `DevicePreferences`, because the log is reachable from setup,
    /// before a server exists and before the dependency graph is built, and the switch has to work
    /// on exactly that screen.
    nonisolated static func setFileSinkEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: fileSinkDefaultsKey)
        fileSinkEnabled = enabled
        if enabled {
            startFileSink()
        } else {
            LogTap.shared.note("[LogTap] file sink off; the file on disk is left where it is")
        }
    }

    /// A factory reset: the sink stops and both files go. On the file queue, so a line already
    /// queued lands before the removal and none after it (appends never create the file).
    nonisolated static func discardPersistedLog() {
        fileSinkEnabled = false
        let urls = persistedLogURLs
        fileQueue.async {
            sinkLock.lock()
            sinkHandle.close()
            sinkLock.unlock()
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    nonisolated static var fileSinkURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sodalite-log.txt")
    }

    nonisolated static var rotatedFileSinkURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sodalite-log.1.txt")
    }

    /// Oldest first, the order an export concatenates them in.
    nonisolated static var persistedLogURLs: [URL] {
        [rotatedFileSinkURL, fileSinkURL].compactMap { $0 }
    }

    /// One marker per launch, so a file with nothing in it after it says "no lines were emitted"
    /// rather than "the sink is broken".
    ///
    /// Arming **appends**, it does not start a fresh file. The sink exists for transitions the
    /// memory ring rolls out, and those repros span an hour of sleep plus a look at other apps
    /// afterwards, in which tvOS may evict the app: truncating here would make the relaunch that
    /// follows the thing that destroys the evidence. A full file rotates on the next line instead.
    nonisolated static func startFileSink() {
        guard let url = fileSinkURL else { return }
        fileQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        // environmentLine on its own (SodaliteApp.init) is noted before fileSinkEnabled is set, so
        // it never reached the file; carrying it here instead covers both the launch path and the
        // mid-session toggle, so every persisted segment names the build that wrote it
        // (Audit 2026-09-25 DIAG-5, the AetherPlayer#7 failure mode environmentLine exists to
        // prevent).
        LogTap.shared.note("[LogTap] file sink armed at \(url.path) | \(environmentLine)")
    }

    nonisolated private func appendToFile(_ line: String) {
        Self.appendPreformattedLinesToFileSink([line])
    }

    /// Writes already-stamped, already-redacted lines straight to the file sink, bypassing
    /// `note(_:)`'s own stamp+redact pass (for lines that already carry both, e.g. imported Top
    /// Shelf lines in `importShelfLines`). No-op when the sink is off.
    nonisolated static func appendPreformattedLinesToFileSink(_ lines: [String]) {
        guard fileSinkEnabled, let url = fileSinkURL, let rotated = rotatedFileSinkURL else { return }
        // Audit PTD-207: the queue used to be unbounded, so a stalled disk grew it without limit.
        guard fileBacklog.admit(lines.count) else { return }
        fileQueue.async {
            let dropped = fileBacklog.takeDropped()
            if dropped > 0 {
                append("\(LogTimestamp.stamp())  [LogTap] file sink was behind, dropped \(dropped) lines",
                       to: url, rotatingTo: rotated, segmentBytes: fileSegmentBytes)
            }
            for line in lines {
                append(line, to: url, rotatingTo: rotated, segmentBytes: fileSegmentBytes)
            }
            fileBacklog.finish(lines.count)
        }
    }

    /// Lines queued for the file but not written yet. Past the limit a line is dropped and counted, and
    /// the next batch that gets through writes one line saying how many.
    nonisolated static let fileBacklog = FileSinkBacklog(limit: 4096)

    /// The one open handle of the sink. Only touched on `fileQueue`.
    private nonisolated static let sinkHandle = SinkHandle()
    private nonisolated static let sinkLock = NSLock()

    /// Synchronous and static so the rotation can be tested against a small segment. Only ever called
    /// on `fileQueue`, which is what makes the check-then-rename below race free.
    ///
    /// The handle stays open between lines (audit PTD-207: open, seek and close per line is three
    /// syscalls on every log line of a live session). The marker is written straight to the new file
    /// rather than through `note(_:)`, which would come back here on the queue this is already running on.
    nonisolated static func append(_ line: String, to url: URL, rotatingTo rotated: URL, segmentBytes: Int) {
        let sink = sinkHandle
        // Production calls arrive on `fileQueue`; tests call this from their own threads.
        sinkLock.lock()
        defer { sinkLock.unlock() }
        guard sink.open(url) else { return }
        var text = line + "\n"
        if sink.size >= UInt64(segmentBytes) {
            sink.close()
            let manager = FileManager.default
            try? manager.removeItem(at: rotated)
            guard (try? manager.moveItem(at: url, to: rotated)) != nil else { return }
            manager.createFile(atPath: url.path, contents: nil)
            guard sink.open(url) else { return }
            text = "\(LogTimestamp.stamp())  [LogTap] file sink rotated, earlier lines are in "
                + "\(rotated.lastPathComponent)\n" + text
        }
        sink.write(Data(text.utf8))
    }

    /// Moves what the Top Shelf extension logged in its own process into the buffer (see `ShelfLog`).
    ///
    /// Those lines are already stamped and redacted, so they skip `note(_:)`: re-stamping would date
    /// them to the moment the app woke up rather than the moment the shelf ran. They are merged in by
    /// stamp, because they are usually older than what the app has logged since launch.
    nonisolated func importShelfLines() {
        #if os(tvOS)
        guard let file = ShelfLogFile.shared else { return }
        DispatchQueue.global(qos: .utility).async {
            let imported = file.drain()
            guard !imported.isEmpty else { return }
            // Already stamped and redacted, so this skips note(_:) for the same re-stamping reason
            // as the ring merge below, but that meant these lines never reached the persisted file
            // either: once they rolled off the 300-line ring they were gone for good, in exactly the
            // case (the extension runs while the app is backgrounded) the sink exists to hold
            // (Audit 2026-09-25 DIAG-6).
            Self.appendPreformattedLinesToFileSink(imported)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let tap = LogTap.shared
                    tap.lines = LogTap.merged(tap.lines, imported, limit: tap.maxLines)
                    tap.sequenceNumber += imported.count
                }
            }
        }
        #endif
    }

    /// Both inputs in stamp order, output in stamp order and at most `limit` long, the oldest dropped.
    /// A tie keeps the buffer's own line first.
    nonisolated static func merged(_ existing: [String], _ imported: [String], limit: Int) -> [String] {
        var result: [String] = []
        result.reserveCapacity(existing.count + imported.count)
        var i = 0
        var j = 0
        while i < existing.count || j < imported.count {
            if j == imported.count
                || (i < existing.count
                    && existing[i].prefix(LogTimestamp.width) <= imported[j].prefix(LogTimestamp.width)) {
                result.append(existing[i])
                i += 1
            } else {
                result.append(imported[j])
                j += 1
            }
        }
        return Array(result.suffix(limit))
    }

    /// Wipe the buffer (e.g. between playback sessions so the next
    /// test starts with a clean slate).
    nonisolated func clear() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.lines.removeAll()
                self?.sequenceNumber = 0
            }
        }
    }
}

/// Counts lines waiting for the file queue. `admit` refuses a batch that would pass the limit.
nonisolated final class FileSinkBacklog: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0

    init(limit: Int) { self.limit = limit }

    func admit(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending + count > limit {
            dropped += count
            return false
        }
        pending += count
        return true
    }

    func finish(_ count: Int) {
        lock.lock()
        pending -= count
        lock.unlock()
    }

    func takeDropped() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = dropped
        dropped = 0
        return value
    }
}

/// A write handle kept open for the sink, with the size it has reached. Not thread safe on its own,
/// `LogTap.sinkLock` serialises every call.
private nonisolated final class SinkHandle: @unchecked Sendable {
    private var handle: FileHandle?
    private var url: URL?
    private(set) var size: UInt64 = 0
    private var writesSinceCheck = 0

    /// True when a handle for `target` is ready. Reopens when the target changed, and when the file was
    /// removed behind our back (the system may purge Caches), which is checked every 64 writes.
    func open(_ target: URL) -> Bool {
        if handle != nil, url == target {
            writesSinceCheck += 1
            if writesSinceCheck < 64 { return true }
            writesSinceCheck = 0
            if FileManager.default.fileExists(atPath: target.path) { return true }
        }
        close()
        guard let fresh = try? FileHandle(forWritingTo: target) else { return false }
        size = (try? fresh.seekToEnd()) ?? 0
        handle = fresh
        url = target
        return true
    }

    func write(_ data: Data) {
        guard let handle else { return }
        if (try? handle.write(contentsOf: data)) != nil {
            size += UInt64(data.count)
        } else {
            close()
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
        url = nil
        size = 0
    }
}
