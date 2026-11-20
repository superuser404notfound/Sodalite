import Foundation

/// Sodalite#62: switching the Catalog tab off also switches off the Catalog section in Search,
/// which shows the same unavailable, requestable titles. The person filmography stays on with a
/// connected Seerr: hiding it silently read as an app that cannot show one (Sodalite#143).
/// Requesting from a Jellyfin detail page is unaffected: that is about owned content.
enum SeerrSurfacePolicy {

    @MainActor
    static func browsingEnabled(appState: AppState, appearance: AppearancePreferences) -> Bool {
        appState.isSeerrConnected && !appearance.isTabHidden(.catalog)
    }
}
