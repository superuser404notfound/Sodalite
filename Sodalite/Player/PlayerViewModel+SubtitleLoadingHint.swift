import AetherEngine
import Foundation

/// A picked subtitle that is still loading says so where its first line will appear. Under a transcode
/// the first fetch of an embedded text track waits for Jellyfin to extract every subtitle from the whole
/// file, 88 s for an 18 GB file on the test server, and an empty screen for that long reads as a broken
/// track (Sodalite#253).
enum SubtitleLoadingHint {
    /// A sidecar from a warm cache or an embedded track lands well inside this, so they never flash it.
    static let delay: Duration = .milliseconds(1500)

    /// Covers every playhead, a positive subtitle delay included, which looks up before zero. The
    /// lookup bound that goes with it is unbounded too.
    static let maxCueDuration = Double.greatestFiniteMagnitude

    static let cue = SubtitleCue(id: -253, startTime: -.greatestFiniteMagnitude, endTime: .greatestFiniteMagnitude,
                                 body: .text(String(localized: "player.subtitle.loading", defaultValue: "Loading subtitles…")))
}

extension PlayerViewModel {
    /// Only for a track the viewer turned on. The silent forced fallback and the temporary skip-back and
    /// muted-playback windows load without a pick, and a hint there would announce subtitles the menu
    /// says are off.
    var showsSubtitleLoadingHint: Bool {
        subtitleLoadingHintVisible && activeSubtitleIndex != nil && subtitleCues.isEmpty && assRenderer == nil
            && skipBackSubtitleWindow == nil && systemCaptionWindow == nil
    }

    /// The primary line the subtitle layers draw.
    var overlayCues: [SubtitleCue] {
        showsSubtitleLoadingHint ? [SubtitleLoadingHint.cue] : subtitleCues
    }

    var overlayMaxCueDuration: Double {
        showsSubtitleLoadingHint ? SubtitleLoadingHint.maxCueDuration : subtitleMaxCueDuration
    }

    /// The hint is plain text, so the raw-ASS stripper the active codec would select must not touch it.
    var overlaySubtitleCodec: String? {
        showsSubtitleLoadingHint ? nil : activeSubtitleCodec
    }

    /// Mirrors the engine's flag. A repeated `true` keeps the clock already running, so a republish
    /// does not push the hint back by another delay.
    func subtitleLoadingDidChange(_ loading: Bool) {
        guard loading else {
            subtitleLoadingHintTask?.cancel()
            subtitleLoadingHintTask = nil
            subtitleLoadingHintVisible = false
            return
        }
        guard subtitleLoadingHintTask == nil, !subtitleLoadingHintVisible else { return }
        let delay = subtitleLoadingHintDelay
        subtitleLoadingHintTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.subtitleLoadingHintTask = nil
            self.subtitleLoadingHintVisible = true
        }
    }
}
