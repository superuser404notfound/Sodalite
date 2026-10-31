import Foundation
import Combine
import AetherEngine
#if canImport(UIKit)
import UIKit
#endif

/// One theme song, ready to stream.
struct ThemeSongTarget: Equatable, Sendable {
    let songID: String
    let url: URL
}

/// Where a theme song is heard. `AVThemeSongOutput` in the app, a recorder in tests.
@MainActor
protocol ThemeSongOutput: AnyObject {
    var currentSongID: String? { get }
    func play(_ target: ThemeSongTarget)
    func stop()
}

/// Sodalite#219: plays the theme song of the detail page on top, opt in per profile.
///
/// Every detail page holds a claim while it is on screen, and the newest claim wins. A page that pushes
/// the next one hands over without a gap when both resolve to the same song, which is what a season of
/// the series it came from does. A page that goes away is released after `releaseGrace`, so the
/// disappear of one page and the appear of the next never stop the song in between.
///
/// Playback of anything else (engine loading, playing, paused, seeking, a player on screen) silences it,
/// and the page on top fades back in `resumeDelay` after that playback is gone, as Jellyfin Web does.
@MainActor
final class ThemeSongPlayer {
    struct Claim: Hashable {
        fileprivate let id = UUID()
    }

    private struct Entry {
        let claim: Claim
        let key: String
        let resolve: @MainActor () async -> ThemeSongTarget?
        var spent = false
    }

    private let output: ThemeSongOutput
    private let isEnabled: @MainActor () -> Bool
    private let isBlocked: @MainActor () -> Bool
    private let releaseGrace: Duration
    private let resumeDelay: Duration

    private var entries: [Entry] = []
    /// Per item, nil included, so walking back to a page plays without a round trip. Dropped once no
    /// page is left, which is also how a song added on the server gets picked up.
    private var resolved: [String: ThemeSongTarget?] = [:]
    private var evaluation: Task<Void, Never>?
    private var pendingRelease: Task<Void, Never>?
    private var pendingResume: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        output: ThemeSongOutput,
        isEnabled: @escaping @MainActor () -> Bool,
        isBlocked: @escaping @MainActor () -> Bool,
        releaseGrace: Duration = .milliseconds(250),
        // The engine releases the shared audio session off-main once its playback stops; a song started
        // before that lands would be cut by it.
        resumeDelay: Duration = .seconds(1)
    ) {
        self.output = output
        self.isEnabled = isEnabled
        self.isBlocked = isBlocked
        self.releaseGrace = releaseGrace
        self.resumeDelay = resumeDelay
    }

    /// `key` names the item (server and id); `resolve` fetches its song once per key.
    func claim(key: String, resolve: @escaping @MainActor () async -> ThemeSongTarget?) -> Claim {
        let claim = Claim()
        entries.append(Entry(claim: claim, key: key, resolve: resolve))
        evaluate()
        return claim
    }

    func release(_ claim: Claim) {
        entries.removeAll { $0.claim == claim }
        pendingRelease?.cancel()
        pendingRelease = Task { [weak self, releaseGrace] in
            try? await Task.sleep(for: releaseGrace)
            guard !Task.isCancelled, let self else { return }
            if self.entries.isEmpty { self.resolved.removeAll() }
            self.evaluate()
        }
    }

    /// Something outside the engine makes sound (a YouTube trailer) or the app leaves the front: stop, and
    /// keep the pages that are open now silent until `resume()`.
    func silence() {
        evaluation?.cancel()
        for index in entries.indices { entries[index].spent = true }
        output.stop()
    }

    /// The trailer closed or the app is back in front: the page on top plays again.
    func resume() {
        for index in entries.indices { entries[index].spent = false }
        evaluate()
    }

    /// Re-checks against the switch and the blockers, after the setting changed or playback ended.
    func evaluate() {
        evaluation?.cancel()
        guard let top = entries.last, !top.spent, isEnabled() else {
            output.stop()
            return
        }
        if isBlocked() {
            output.stop()
            return
        }
        if let cached = resolved[top.key] {
            apply(cached)
            return
        }
        let claim = top.claim
        let key = top.key
        let resolve = top.resolve
        evaluation = Task { [weak self] in
            let target = await resolve()
            guard !Task.isCancelled, let self else { return }
            self.resolved[key] = target
            guard self.entries.last?.claim == claim, self.entries.last?.spent == false,
                  self.isEnabled(), !self.isBlocked() else { return }
            self.apply(target)
        }
    }

    private func apply(_ target: ThemeSongTarget?) {
        guard let target else {
            output.stop()
            return
        }
        guard output.currentSongID != target.songID else { return }
        output.play(target)
    }

    /// Playback started or is still around: stop now, and drop a resume that was waiting.
    func playbackDidStart() {
        pendingResume?.cancel()
        evaluation?.cancel()
        output.stop()
    }

    /// Playback may be over: the page on top comes back once `resumeDelay` has passed with nothing
    /// playing. `evaluate` re-checks the blockers, so a player still on screen keeps it silent.
    func playbackDidSettle() {
        pendingResume?.cancel()
        pendingResume = Task { [weak self, resumeDelay] in
            try? await Task.sleep(for: resumeDelay)
            guard !Task.isCancelled, let self else { return }
            self.evaluate()
        }
    }

    /// Wires the app's own signals: engine activity, a player on screen, the app leaving the front.
    func observe(engine: AetherEngine) {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if Self.isQuiet(state) { self.playbackDidSettle() } else { self.playbackDidStart() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .playerModalPresenceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if PlayerModalPresence.isPlayerActive { self.playbackDidStart() } else { self.playbackDidSettle() }
            }
            .store(in: &cancellables)
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.silence() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resume() }
            .store(in: &cancellables)
        #endif
    }

    /// Only a session-less engine leaves room: a paused music queue still owns the speakers, and the
    /// engine releases the shared audio session when that session stops.
    nonisolated static func isQuiet(_ state: PlaybackState) -> Bool {
        switch state {
        case .idle, .ended, .error: true
        case .loading, .playing, .paused, .seeking: false
        }
    }
}
