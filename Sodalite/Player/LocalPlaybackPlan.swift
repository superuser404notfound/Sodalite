import Foundation

/// What a downloaded item needs to play with no server (Sodalite#81). The subtitle method is the
/// route the FILE came from, not the one reported: a transcode renumbered the streams and its text
/// tracks exist only as sidecars, exactly as when it was streamed.
struct LocalPlaybackPlan {
    let url: URL
    let source: PlaybackMediaSource
    let subtitleMethod: PlayMethod
    let startTicks: Int64?

    static func make(_ item: DownloadedItem, startFromBeginning: Bool) -> LocalPlaybackPlan? {
        guard let url = item.mediaURL else { return nil }
        let position = item.manifest.progress.positionTicks
        return LocalPlaybackPlan(
            url: url,
            source: item.snapshot.source,
            subtitleMethod: item.manifest.route == .transcode ? .transcode : .directPlay,
            startTicks: startFromBeginning || position <= 0 ? nil : position)
    }
}

enum LocalPlaybackError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        String(localized: "downloads.error.fileMissing", defaultValue: "The downloaded file is missing.")
    }
}
