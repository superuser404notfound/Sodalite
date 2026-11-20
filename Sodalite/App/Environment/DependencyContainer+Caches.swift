import Foundation

/// What Sodalite keeps on this device, in bytes, as the Settings screen shows it.
struct CacheFootprint: Equatable, Sendable {
    /// The entries Sodalite writes itself: Home's shelf and the tile grids.
    let feedAndLists: Int
    /// Everything the Jellyfin and Seerr clients cached from a response.
    let serverResponses: Int
    /// Artwork on disk. The decoded copies in memory are not in here; see the note in the extension.
    let artwork: Int
    /// Fonts an ASS track embedded (`ASSFontCache`). No row of its own: the player drops them when
    /// a session ends, so outside one this is zero, but a leftover set must still arm the button.
    var subtitleFonts: Int = 0

    var total: Int { feedAndLists + serverResponses + artwork + subtitleFonts }
    var isEmpty: Bool { total == 0 }
}

/// Reading and dropping every cache the app keeps (Sodalite#117, DrHurt asked for a way to see it
/// and a way to clear it).
///
/// It lives here rather than in the view because the container is the only place that holds all of
/// them: the Seerr client is built in its init and reachable nowhere else, and a screen that went
/// looking for the stores itself would be a second list to keep in step with this one.
///
/// The whole set, and the reason each figure is what it is:
///
/// - The entry cache Sodalite writes itself, `FilterCache`, as JSON under `Library/Caches`. Summed
///   over its files.
/// - The response cache, `sodalite-http-cache`. The Jellyfin client and the Seerr client each build
///   a `URLCache` with that same disk path, so they are two handles on ONE directory: the figure is
///   read from one of them, because adding both would count the same bytes twice, and the clear
///   walks both, because the memory half of a URLCache belongs to its own instance. The discovery
///   client has no cache at all (`urlCache = nil`), so it is not in here and does not need to be.
/// - Artwork, `sodalite-image-cache`. The decoded images in `ImageCache` ride along when clearing
///   but carry no figure: they are memory the next launch never sees, not something the device keeps.
/// - Subtitle fonts, `ASSFontCache` under `Library/Caches/ass-fonts`. Summed over its files.
///
/// `CachedDataTests` walks the sources for every `URLCache(… diskPath:)` and fails if one is not
/// named in this file. A cache added later and wired into neither would make both the figure and
/// the button quietly wrong, which is the failure this screen exists to rule out.
extension DependencyContainer {

    /// Synchronous file IO, so call it off the main actor. `nonisolated` for exactly that reason.
    nonisolated func cacheFootprint() -> CacheFootprint {
        CacheFootprint(
            feedAndLists: FilterCache.shared.diskUsage(),
            serverResponses: (httpClient as? HTTPClient)?.cacheDiskUsage ?? 0,
            artwork: ImageFetch.cacheDiskUsage,
            subtitleFonts: ASSFontCache.diskUsage()
        )
    }

    /// Drops all of it. Nothing here is a source of truth, so nothing is lost: the next screen
    /// fetches from the server again.
    func clearCachedData() {
        FilterCache.shared.clearAll()
        (httpClient as? HTTPClient)?.clearCache()
        seerrHTTPClient.clearCache()
        ImageFetch.clearCache()
        ImageCache.shared.clear()
        ASSFontCache.removeAll()
        sessionNote("caches: cleared on request from Settings.")
    }
}
