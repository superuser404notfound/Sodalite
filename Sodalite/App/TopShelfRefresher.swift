#if os(tvOS)
import TVServices
#endif

/// Tells tvOS the Top Shelf's backing data changed, so it re-asks the extension instead of
/// serving its last snapshot until its own refresh cycle comes around. No-op off tvOS: the
/// iOS target compiles the same sources and has no shelf.
enum TopShelfRefresher {
    /// Cheap and idempotent, so call sites fire it unconditionally rather than diffing against
    /// what the shelf currently shows.
    ///
    /// Renders the cell artwork first and tells tvOS afterwards. The other order is what the
    /// extension used to pay for: tvOS asks immediately, finds nothing on disk, and holds the row
    /// back while it downloads and composites up to twenty pictures. `TopShelfPrerender` coalesces,
    /// so the triggers that fire together still cost one pass.
    nonisolated static func invalidate() {
        #if os(tvOS)
        Task.detached(priority: .utility) {
            await TopShelfPrerender.run()
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
        #endif
    }
}
