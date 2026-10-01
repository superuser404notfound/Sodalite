import Foundation

/// Sodalite#175: which `PlayerHostController`s are still alive, and what the system believes is playing.
/// After a multiview session the Control Center kept a "playing" card for a channel nothing played any
/// more. Sodalite's Now Playing is AVKit's, one registration per controller, so the open question is
/// whether a controller that gave its player away (hand-off, tile full screen) outlives its dismissal.
/// Diagnostics only: nothing here holds a controller or decides anything.
@MainActor
enum PlayerHostDiagnostics {
    private static var counter = 0
    private static let hosts = NSHashTable<PlayerHostController>.weakObjects()
    private static var aftermath: Task<Void, Never>?

    static func makeID() -> String {
        counter += 1
        return "h\(counter)"
    }

    static func register(_ host: PlayerHostController) {
        hosts.add(host)
    }

    static var liveHosts: [PlayerHostController] {
        hosts.allObjects.sorted { $0.diagnosticID.localizedStandardCompare($1.diagnosticID) == .orderedAscending }
    }

    static func liveSummary() -> String {
        let live = liveHosts.map(\.diagnosticSummary)
        return live.isEmpty ? "none" : live.joined(separator: "; ")
    }

    static func noteLiveHosts(_ reason: String) {
        LogTap.shared.note("[NowPlaying] \(reason): live hosts=[\(liveSummary())]")
    }

    /// A while after playback stopped, when every dismissed controller should be gone: the controllers
    /// that are not, and (Debug builds) the card the system still holds for this app.
    static func noteAftermath(_ reason: String, after seconds: Double = 3) {
        aftermath?.cancel()
        aftermath = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            aftermath = nil
            let label = String(format: "%.0fs after %@", seconds, reason)
            noteLiveHosts(label)
            noteSystemCard(label)
        }
    }

    /// The system's own Now Playing record, read through MediaRemote. Debug builds only: the symbols are
    /// private, and a string naming them is exactly what the App Store's static analysis looks for.
    static func noteSystemCard(_ reason: String) {
        #if DEBUG
        typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
        typealias PIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let infoSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            LogTap.shared.note("[NowPlaying] \(reason): system card unreadable (no MediaRemote symbol)")
            return
        }
        let ownPID = getpid()
        unsafeBitCast(infoSymbol, to: InfoFn.self)(.global()) { info in
            guard let info = info as? [String: Any], !info.isEmpty else {
                LogTap.shared.note("[NowPlaying] \(reason): system card=none")
                return
            }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] ?? "?"
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?? "?"
            LogTap.shared.note("[NowPlaying] \(reason): system card title=\(title) rate=\(rate) keys=\(info.count)")
        }
        if let pidSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
            unsafeBitCast(pidSymbol, to: PIDFn.self)(.global()) { pid in
                LogTap.shared.note("[NowPlaying] \(reason): system now playing app is \(pid == ownPID ? "this app" : "pid \(pid)")")
            }
        }
        #endif
    }
}
