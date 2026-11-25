import AetherEngine
import Foundation

/// A picked subtitle that is still loading says so where its first line will appear. Under a transcode
/// the first fetch of an embedded text track waits for Jellyfin to extract every subtitle from the whole
/// file, 88 s for an 18 GB file on the test server, and an empty screen for that long reads as a broken
/// track (Sodalite#253).
enum SubtitleLoadingHint {
    /// A sidecar from a warm cache or an embedded track lands well inside this, so they never flash it.
    static let delay: Duration = .milliseconds(1500)

    /// Active at every playhead, whatever the subtitle delay: starts at 0 and never ends, and the
    /// lookup bound that goes with it is unbounded too.
    static let maxCueDuration = Double.greatestFiniteMagnitude

    static func cue(text: String) -> SubtitleCue {
        SubtitleCue(id: -253, startTime: 0, endTime: .greatestFiniteMagnitude, body: .text(text))
    }

    static var text: String {
        String(localized: "player.subtitle.loading", defaultValue: "Loading subtitles…")
    }
}

extension PlayerViewModel {
    /// Shown only for a track the viewer has on: the silent forced fallback loads without a pick, and a
    /// hint there would announce subtitles the menu says are off.
    var showsSubtitleLoadingHint: Bool {
        subtitleLoadingHintVisible && activeSubtitleIndex != nil && subtitleCues.isEmpty && assRenderer == nil
    }

    /// The primary line the subtitle layers draw.
    var overlayCues: [SubtitleCue] {
        showsSubtitleLoadingHint ? [SubtitleLoadingHint.cue(text: SubtitleLoadingHint.text)] : subtitleCues
    }

    var overlayMaxCueDuration: Double {
        showsSubtitleLoadingHint ? SubtitleLoadingHint.maxCueDuration : subtitleMaxCueDuration
    }

    /// The hint is plain text; the raw-ASS stripper the active codec would select must not touch it.
    var overlaySubtitleCodec: String? {
        showsSubtitleLoadingHint ? nil : activeSubtitleCodec
    }

    func subtitleLoadingDidChange(_ loading: Bool) {
        subtitleLoadingHintTask?.cancel()
        subtitleLoadingHintTask = nil
        guard loading else {
            subtitleLoadingHintVisible = false
            return
        }
        subtitleLoadingHintTask = Task { [weak self] in
            try? await Task.sleep(for: SubtitleLoadingHint.delay)
            guard !Task.isCancelled, let self else { return }
            self.subtitleLoadingHintVisible = true
        }
    }
}
