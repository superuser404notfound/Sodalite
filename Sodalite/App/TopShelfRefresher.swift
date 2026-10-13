#if os(tvOS)
import TVServices
import UIKit
#endif

/// Tells tvOS the Top Shelf's backing data changed, so it re-asks the extension instead of
/// serving its last snapshot until its own refresh cycle comes around. No-op off tvOS: the
/// iOS target compiles the same sources and has no shelf.
enum TopShelfRefresher {
    /// Cheap and idempotent, so call sites fire it unconditionally rather than diffing against
    /// what the shelf currently shows.
    ///
    /// Renders the cell artwork first and tells tvOS afterwards. The other order hands tvOS a row
    /// the extension can only show with remote artwork and the system bar. `TopShelfPrerender`
    /// coalesces, so the triggers that fire together still cost one pass.
    nonisolated static func invalidate() {
        #if os(tvOS)
        Task.detached(priority: .utility) {
            await refresh()
        }
        #endif
    }

    /// `invalidate()` for a caller that has to know when it is done, such as one holding a
    /// background task open for it.
    nonisolated static func refresh() async {
        #if os(tvOS)
        await TopShelfPrerender.run()
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    #if os(tvOS)
    /// One last pass on every trip to the background, held open by a background task. tvOS asks the
    /// extension for the shelf right after Home, and an `invalidate()` fired shortly before (a row
    /// marked played, a profile or accent change) is a detached task the suspension freezes halfway.
    /// The row then keeps remote artwork with the system's white bar until the app runs again.
    /// Also picks up resume positions another device moved while the app sat in the foreground.
    @MainActor private static var suspensionAssertion = UIBackgroundTaskIdentifier.invalid

    @MainActor static func refreshBeforeSuspension() {
        guard suspensionAssertion == .invalid else { return }
        suspensionAssertion = UIApplication.shared.beginBackgroundTask(withName: "topshelf-suspend") {
            MainActor.assumeIsolated { endSuspensionAssertion() }
        }
        Task { @MainActor in
            await refresh()
            endSuspensionAssertion()
        }
    }

    @MainActor private static func endSuspensionAssertion() {
        guard suspensionAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(suspensionAssertion)
        suspensionAssertion = .invalid
    }
    #endif
}
