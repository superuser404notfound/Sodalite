import Foundation
import AetherEngine

/// Sodalite#175: why a multiview tile could not tune. Inferred, not matched: Jellyfin's exact answer for an
/// exhausted tuner is unverified, so any HTTP failure of the tuner open reads as "no free tuner".
enum LiveTuneRefusal: Equatable, Sendable {
    case tunerUnavailable
    case providerLimit(status: Int)

    static let providerRefusalStatuses: Set<Int> = [403, 429, 458, 503, 509]

    static func classify(tunerOpenError: Error?, ingestError: HLSIngestError?) -> LiveTuneRefusal? {
        if case .playlistUnreachable(let status)? = ingestError, providerRefusalStatuses.contains(status) {
            return .providerLimit(status: status)
        }
        if case .httpError? = tunerOpenError as? APIError { return .tunerUnavailable }
        return nil
    }

    var title: String {
        switch self {
        case .tunerUnavailable:
            String(localized: "multiview.error.tuner.title", defaultValue: "No free tuner")
        case .providerLimit:
            String(localized: "multiview.error.provider.title", defaultValue: "Connection limit reached")
        }
    }

    var body: String {
        switch self {
        case .tunerUnavailable:
            String(localized: "multiview.error.tuner.body",
                   defaultValue: "The server could not open another channel right now. All tuners may be in use.")
        case .providerLimit(let status):
            String(format: String(localized: "multiview.error.provider.body",
                                  defaultValue: "The provider does not allow another concurrent connection (HTTP %lld)."),
                   status)
        }
    }
}
