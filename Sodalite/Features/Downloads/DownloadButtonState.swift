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
    var id: String { quality.rawValue }

    /// The same filter as the player picker (#87): a rung that would not transcode this file is the
    /// original under another name. Always best first, so the list reads the same every time.
    static func options(sourceBitrate: Int?, sourceSize: Int64?, runtimeTicks: Int64?) -> [DownloadRungOption] {
        StreamingQuality.allCases.filter { $0 == .original || $0.bites(sourceBitrate: sourceBitrate) }.map {
            DownloadRungOption(quality: $0, estimatedBytes: DownloadPlanner.estimatedBytes(
                quality: $0, sourceBitrate: sourceBitrate, sourceSize: sourceSize, runtimeTicks: runtimeTicks))
        }
    }
}
