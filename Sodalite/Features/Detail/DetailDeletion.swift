import Foundation

/// The cleanup after a deletion from a detail page, shared by Movie and Series (audit DET-R201).
///
/// The Jellyfin item goes first and the Seerr step second, so a Seerr failure arrives as a thrown
/// error for a file that is already gone, and a multi-season delete can fail at season N after
/// removing 1...N-1. The cleanup has to follow what was deleted, not whether the call returned
/// (audit DET-201). The Seerr failure is still reported, as the partial toast.
@MainActor
enum DetailDeletion {
    typealias Outcome = MediaDeletionSheet.DeletionOutcome

    /// Whether the Jellyfin item is gone given how the call ended. `assumesPartialRemoval` is the
    /// season delete, which has no Seerr stage and may have removed some seasons before failing.
    static func itemsRemoved(after error: Error?, assumesPartialRemoval: Bool = false) -> Bool {
        guard let error else { return true }
        if assumesPartialRemoval { return true }
        return (error as? MediaDeletionError)?.partialSuccess == true
    }

    /// Runs `delete`, then the cleanup for what it removed, and returns the toast outcome.
    /// `popsWhenRemoved` is the whole-title delete; seasons stay on the page and refresh instead.
    /// The page closes by itself only on full success. After a partial one the sheet keeps its
    /// warning until Cancel, and the caller closes the page from the sheet's dismissal
    /// (audit review R-DET-1).
    static func run(
        serverID: String?,
        cascadedToArrStack: Bool,
        popsWhenRemoved: Bool,
        assumesPartialRemoval: Bool = false,
        evictFilterCache: (String) -> Void = { FilterCache.shared.evict(serverID: $0) },
        post: (Notification.Name) -> Void = { NotificationCenter.default.post(name: $0, object: nil) },
        popDelay: Duration = .milliseconds(1100),
        pop: @escaping @MainActor () -> Void,
        refreshAfterRemoval: () async -> Void = {},
        delete: () async throws -> Void
    ) async -> Outcome {
        var failure: Error?
        do { try await delete() } catch { failure = error }

        if itemsRemoved(after: failure, assumesPartialRemoval: assumesPartialRemoval) {
            // Every profile on this server, not just the active one: the file is gone for all of them.
            if let serverID { evictFilterCache(serverID) }
            post(.homeItemDidDelete)
            // The cascade also cleared the title's open Seerr requests, so the request lists are stale.
            if cascadedToArrStack { post(.seerrRequestsDidChange) }
            if popsWhenRemoved {
                if failure == nil {
                    // Pop after the sheet's toast hold.
                    Task { @MainActor in
                        try? await Task.sleep(for: popDelay)
                        pop()
                    }
                }
            } else {
                await refreshAfterRemoval()
            }
        }
        return failure.map(Outcome.from) ?? .success
    }
}
