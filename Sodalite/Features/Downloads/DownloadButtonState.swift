import Foundation

enum DownloadButtonState: Equatable {
    case available, queued, downloading(Double?), paused, failed, downloaded

    static func from(_ item: DownloadedItem?, liveProgress: Double?) -> DownloadButtonState {
        guard let item else { return .available }
        switch item.manifest.state {
        case .queued: return .queued
        case .downloading: return .downloading(liveProgress)
        case .paused: return .paused
        case .failed: return .failed
        case .complete, .missingOnServer: return .downloaded
        }
    }

    var titleKey: String {
        switch self {
        case .available: "downloads.action.download"
        case .queued: "downloads.state.queued"
        case .downloading: "downloads.state.downloading"
        case .paused: "downloads.state.paused"
        case .failed: "downloads.state.failed"
        case .downloaded: "downloads.state.downloaded"
        }
    }

    var progressFraction: Double? {
        if case .downloading(let fraction) = self { return fraction }
        return nil
    }

    var systemImage: String {
        switch self {
        case .available: "arrow.down.circle"
        case .queued: "clock"
        case .downloading: "arrow.down.circle.dotted"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle"
        // Filled, not a checkmark: the checkmark is the watched state one button over.
        case .downloaded: "arrow.down.circle.fill"
        }
    }
}

struct DownloadRungOption: Identifiable, Equatable {
    let quality: StreamingQuality
    let estimatedBytes: Int64?
    /// The version an original downloads, set only where the item has more than one (Sodalite#200).
    var source: MediaSource? = nil
    var id: String { [quality.rawValue, source?.id].compactMap { $0 }.joined(separator: "-") }

    /// The same filter as the player picker (#87): a rung that would not transcode this file is the
    /// original under another name. Always best first, so the list reads the same every time. A user
    /// without video transcoding gets the original under every rung, so only Original is offered (Sodalite#202).
    static func options(sourceBitrate: Int?, sourceSize: Int64?, runtimeTicks: Int64?,
                        canTranscodeVideo: Bool = true) -> [DownloadRungOption] {
        StreamingQuality.allCases.filter {
            $0 == .original || (canTranscodeVideo && $0.bites(sourceBitrate: sourceBitrate))
        }.map {
            DownloadRungOption(quality: $0, estimatedBytes: DownloadPlanner.estimatedBytes(
                quality: $0, sourceBitrate: sourceBitrate, sourceSize: sourceSize, runtimeTicks: runtimeTicks))
        }
    }

    /// Several versions: each one is an original of its own, in the version picker's order, and
    /// the rungs below them transcode the version the page has selected (Sodalite#200).
    static func options(versions: [MediaSource], selected: MediaSource, runtimeTicks: Int64?,
                        canTranscodeVideo: Bool = true, order: VersionOrder = .quality) -> [DownloadRungOption] {
        let originals = versions.ordered(order).map {
            DownloadRungOption(quality: .original, estimatedBytes: $0.size, source: $0)
        }
        let rungs = options(sourceBitrate: selected.bitrate, sourceSize: selected.size, runtimeTicks: runtimeTicks,
                            canTranscodeVideo: canTranscodeVideo)
            .filter { $0.quality != .original }
        return originals + rungs
    }
}
