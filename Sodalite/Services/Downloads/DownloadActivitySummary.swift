import Foundation

/// What the system progress activity shows for a run of downloads (Sodalite#81): the batch is every
/// item started while the activity was up, so "2 of 5" counts what this run set out to do.
struct DownloadActivitySummary: Equatable {
    let finished: Int
    /// Still queued or transferring. A paused or failed item no longer keeps the activity open.
    let pending: Int
    let total: Int
    let receivedBytes: Int64
    let totalBytes: Int64

    var isDone: Bool { pending == 0 }

    static func make(batch: Set<String>, items: [DownloadedItem], liveProgress: [String: Double]) -> DownloadActivitySummary? {
        let members = items.filter { batch.contains($0.id) }
        guard !members.isEmpty else { return nil }
        var finished = 0, pending = 0
        var received: Int64 = 0, total: Int64 = 0
        for item in members {
            let expected = item.manifest.expectedBytes ?? 0
            total += expected
            switch item.manifest.state {
            case .complete, .missingOnServer:
                finished += 1
                received += expected > 0 ? expected : item.manifest.receivedBytes
            case .downloading:
                pending += 1
                received += Int64(Double(expected) * (liveProgress[item.id] ?? 0))
            case .queued:
                pending += 1
            case .paused, .failed:
                break
            }
        }
        return DownloadActivitySummary(finished: finished, pending: pending, total: members.count,
                                       receivedBytes: received, totalBytes: total)
    }
}
