import Foundation
import AVFoundation

/// The theme song's own AVPlayer, outside the engine: a looping stereo stream needs none of it, and the
/// engine's singleton has to stay free for the playback this song makes way for.
///
/// It never touches the audio session's category. The engine declares `.playback` once per process and
/// keeps whatever it finds afterwards, so an `.ambient` set here would carry into every later video.
@MainActor
final class AVThemeSongOutput: ThemeSongOutput {
    /// Theme songs are mastered loud and play under reading, not instead of it.
    static let peakVolume: Float = 0.5
    static let fadeIn: Duration = .milliseconds(1500)
    static let fadeOut: Duration = .milliseconds(600)

    private let player = AVPlayer()
    private(set) var currentSongID: String?
    private var fade: Task<Void, Never>?
    private var start: Task<Void, Never>?
    private var loopObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init() {
        #if !os(macOS)
        player.allowsExternalPlayback = false
        #endif
    }

    func play(_ target: ThemeSongTarget) {
        currentSongID = target.songID
        fade?.cancel()
        start?.cancel()
        start = Task { [weak self] in
            #if !os(macOS)
            // The engine releases the session when its playback stops; an inactive one plays silence.
            // Off the main thread like the engine's own session calls (AE#538).
            await Task.detached(priority: .userInitiated) {
                try? AVAudioSession.sharedInstance().setActive(true)
            }.value
            #endif
            guard let self, !Task.isCancelled, self.currentSongID == target.songID else { return }
            self.begin(target)
        }
    }

    func stop() {
        start?.cancel()
        guard currentSongID != nil else { return }
        currentSongID = nil
        ramp(to: 0, over: Self.fadeOut) { [weak self] in
            guard let self, self.currentSongID == nil else { return }
            self.player.pause()
            self.player.replaceCurrentItem(with: nil)
            self.observeLoop(of: nil)
        }
    }

    private func begin(_ target: ThemeSongTarget) {
        let item = AVPlayerItem(url: target.url)
        player.volume = 0
        player.replaceCurrentItem(with: item)
        observeLoop(of: item)
        let songID = target.songID
        statusObservation = item.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            let reason = item.error.map { String(describing: $0) } ?? "unknown"
            Task { @MainActor in LogTap.shared.note("[ThemeSong] stream failed for \(songID): \(reason)") }
        }
        player.play()
        ramp(to: Self.peakVolume, over: Self.fadeIn)
        LogTap.shared.note("[ThemeSong] playing \(target.songID)")
    }

    /// Seek-to-zero rather than AVPlayerLooper, which does not take the HLS a transcoded song arrives as.
    private func observeLoop(of item: AVPlayerItem?) {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        guard let item else {
            statusObservation = nil
            return
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem === item else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
    }

    private func ramp(to target: Float, over duration: Duration, then completion: (@MainActor () -> Void)? = nil) {
        fade?.cancel()
        let from = player.volume
        let steps = 30
        fade = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: duration / steps)
                guard !Task.isCancelled, let self else { return }
                self.player.volume = from + (target - from) * Float(step) / Float(steps)
            }
            completion?()
        }
    }
}
