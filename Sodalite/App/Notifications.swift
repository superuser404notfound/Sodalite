import Foundation

/// App-wide notification names, centralised because posters/observers span features (player, detail, auth, catalog).
extension Notification.Name {
    static let homeConfigDidChange = Notification.Name("homeConfigDidChange")
    /// Posted by a library grid after the user picked a sort (Sodalite#78) so CloudSyncService mirrors
    /// the choice. Separate from `.homeConfigDidChange`, which HomeView answers with a full row reload
    /// the grid does not need.
    static let librarySortDidChange = Notification.Name("librarySortDidChange")
    static let homeFavoritesDidChange = Notification.Name("homeFavoritesDidChange")
    static let homePlayedDidChange = Notification.Name("homePlayedDidChange")
    /// Posted by PlayerViewModel after a playback-stop report so HomeView/detail refresh Continue Watching / Next Up. Carries PlaybackProgressKey.itemID (the EPISODE for series) + positionTicks; detail views patch that item's in-memory userData directly (authoritative, race-free, vs re-fetch + stale ETag, issue #24).
    static let playbackProgressDidChange = Notification.Name("playbackProgressDidChange")
    /// Posted by detail views after a deletion so HomeView reloads and the item disappears immediately.
    static let homeItemDidDelete = Notification.Name("homeItemDidDelete")
    /// Fires after LoginView completes; ProfileSettingsView pops its "Add another profile" branch, else the success screen hangs (already authenticated, AppRouter doesn't tear down TabRootView).
    static let loginDidComplete = Notification.Name("loginDidComplete")
    /// Posted whenever the set of Seerr requests changed (submitted, or removed from the catalog detail / by a cascading deletion) so CatalogView refreshes loaded request lists. Without it the list keeps its stale rows until an app restart.
    static let seerrRequestsDidChange = Notification.Name("seerrRequestsDidChange")

    /// Posted by SeerrClient when Seerr answers 401 to the session cookie it still holds. CatalogView
    /// re-probes the session and, if it is gone, drops to its "Set up Seerr" state.
    static let seerrSessionRejected = Notification.Name("seerrSessionRejected")

    /// Posted after an admin approves/declines/deletes a request or the admin queue reloads its counts,
    /// so the pending-requests monitor recomputes the Catalog tab badge.
    static let seerrPendingRequestsShouldRefresh = Notification.Name("seerrPendingRequestsShouldRefresh")

    /// iOS: the user tapped a my-request banner; userInfo["itemID"] is the Jellyfin item to open.
    static let myRequestNotificationOpened = Notification.Name("myRequestNotificationOpened")

    /// Posted by CloudSyncService after remote changes were applied locally, so
    /// server lists, pickers, and settings screens refresh.
    static let cloudSyncDidApplyChanges = Notification.Name("cloudSyncDidApplyChanges")

    /// Posted by DependencyContainer after the route resolver moved the active
    /// session to the other URL slot (internal <-> external).
    static let serverRouteDidChange = Notification.Name("serverRouteDidChange")

    static let playerModalPresenceDidChange =
        Notification.Name("playerModalPresenceDidChange")

    /// Posted by PlayerViewModel whenever the running session switches to another item (auto-advance,
    /// play queue, season picker). Detail views follow it so leaving the player lands on the episode
    /// that was watched last, not the one that was started. Carries PlayerItemSwitchKey.item.
    static let playerDidSwitchItem = Notification.Name("playerDidSwitchItem")

    /// Posted by PlayerViewModel after it continued on the item that replaced the one it was asked to
    /// play. A *arr upgrade rewrites the file, Jellyfin ids items by path, so the library holds a new
    /// item and every list still holding the old id would keep failing on it. Carries
    /// LibraryItemReplacementKey.staleID + .item.
    static let libraryItemDidReplace = Notification.Name("libraryItemDidReplace")
}

/// userInfo keys for `.libraryItemDidReplace`.
enum LibraryItemReplacementKey {
    /// `String` id the library no longer has.
    static let staleID = "staleID"
    /// The `JellyfinItem` that took its place.
    static let item = "item"
}

/// userInfo keys for `.playerDidSwitchItem`.
enum PlayerItemSwitchKey {
    /// The `JellyfinItem` the session switched to.
    static let item = "item"
}

/// userInfo keys for `.playbackProgressDidChange`.
enum PlaybackProgressKey {
    /// `String` item id whose playback position changed.
    static let itemID = "itemID"
    /// `Int64` position (in Jellyfin ticks) the player stopped at.
    static let positionTicks = "positionTicks"
}
