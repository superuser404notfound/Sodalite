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

    @Published private(set) var lines: [String] = []

    // 300: holds a full HLS-wrapper session start (init.mp4 dump + m3u8 bodies + per-request logs) through the eventual AVPlayer failure; the previous 80 rolled the init.mp4 summary off before the failure landed.
    private let maxLines = 300

    private nonisolated init() {}

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
#if DEBUG
        appendToFile(line)
#endif
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lines.append(line)
                if self.lines.count > self.maxLines {
                    self.lines.removeFirst(self.lines.count - self.maxLines)
                }
            }
        }
    }

#if DEBUG
    /// A measurement that outlives the app.
    ///
    /// The buffer above is 300 lines in memory, wiped on every launch, which is the right shape for
    /// "what went wrong just now" and the wrong one for a test that runs for ten minutes or that ends
    /// with the app being terminated in the background. A twelve minute pause on a live channel is
    /// both: measured on a device, the session that was meant to produce the evidence came back with
    /// nothing in it but the next launch.
    ///
    /// Debug builds only, so it never runs for anyone but us, and capped so a long session cannot
    /// fill the container. `Library/Caches` because tvOS forbids app writes to `Documents` and the
    /// failure there is a swallowed throw, which reads exactly like "the app produced no logs".
    /// Pull it with:
    ///
    ///     xcrun devicectl device copy from --device <uuid> \
    ///       --domain-type appDataContainer --domain-identifier de.superuser404.Sodalite \
    ///       --user mobile --source Library/Caches/sodalite-log.txt --destination pulled.txt
    private nonisolated static let fileQueue =
        DispatchQueue(label: "de.superuser404.sodalite.logfile")
    private nonisolated static let fileCapBytes = 32 * 1024 * 1024

    nonisolated static var fileSinkURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sodalite-log.txt")
    }

    /// One marker per launch, so a file with nothing in it after it says "no lines were emitted"
    /// rather than "the sink is broken".
    nonisolated static func startFileSink() {
        guard let url = fileSinkURL else { return }
        fileQueue.async {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        LogTap.shared.note("[LogTap] file sink armed at \(url.path)")
    }

    nonisolated private func appendToFile(_ line: String) {
        guard let url = Self.fileSinkURL else { return }
        Self.fileQueue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            guard end < UInt64(Self.fileCapBytes) else { return }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
#endif

    /// Wipe the buffer (e.g. between playback sessions so the next
    /// test starts with a clean slate).
    nonisolated func clear() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.lines.removeAll()
            }
        }
    }
}
