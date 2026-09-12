/// Pixel widths to ask the server for, one per artwork family, for every target.
///
/// The widths used to be literals at each call site, which cost twice (Sodalite#129). The same
/// picture went out at three widths inside one screen, so the server resized it three times and the
/// cache held three copies; and the literals were picked against the UNSCALED `LayoutMetrics` sizes,
/// so every one of them under-requested once Large Cards multiplied the rendered card by 1.3. A
/// landscape card asked for 720px into a 936px slot, a poster 400 into 572.
///
/// Each constant here is the largest rendered size in its family across every tier, times that
/// tier's screen scale (tvOS and iPad render 2x, iPhone 3x), rounded up. `ImageWidthTests` recomputes
/// that from `LayoutMetrics` and `AppearancePreferences.largeCardScale`, so a retuned card size fails
/// there rather than quietly softening artwork on a TV.
///
/// **One number per family, not one per tier and scale.** A width that tracked the live `cardScale`
/// would turn the Large Cards switch into a cache invalidator: every stored image dropped and the
/// whole library resized again on the server, for a setting a user flips to look at it. It would also
/// move the URL under a view that has already drawn, which re-fires `AsyncCachedImage`'s `task(id:)`
/// and flashes the artwork out and back, the failure `ContentLogoTitle` documents for the same reason
/// (Sodalite#97, Sodalite#125). Requesting the ceiling instead costs a few percent of bandwidth on
/// the smaller tiers and buys one cache key per picture on every device, whatever the size class and
/// whatever the setting.
///
/// A ceiling is not free, and the cost lands in memory rather than in bandwidth: `AsyncCachedImage`
/// decodes at source size, so the width asked for here IS the resident bitmap in its 150MB budget.
/// A 16:9 card costs 2.07MB at 960 against 1.17MB at 720, and with Large Cards off nobody draws the
/// difference. That is the price of the two things the ceiling buys, and both were measured
/// failures before: a width that moved with the setting would drop every cached image and re-resize
/// the library on the server the moment someone flipped it, and a width that moved with a measured
/// column re-fires the load and flashes the artwork out and back. Fewer images resident is the
/// cheaper of the three, and `NSCache` evicts rather than fails.
///
/// One bucket per family, not one per surface, for the same reason. The 16:9 tiles (genre, library,
/// provider, episode and program cards) are fixed at 360pt and can never draw past 720, so they
/// carry that overspend without ever using it. Splitting them off would save about a sixth of the
/// cache and reopen the exact hole this file closes: a genre tile's sample item is regularly in a
/// Continue Watching row on the same screen, and the two would then ask for one picture twice.
///
/// Cast portraits keep their own per-tier `LayoutMetrics.castImageWidth`: a circle diameter, no
/// `cardScale`, and it already derived itself correctly before any of this.
enum ImageWidth {

    /// Thumbnail-sized art: the list rows on collection, playlist and Watch Stats
    /// (`LayoutMetrics.listPosterSize`, 140pt on tvOS), the player's episode and chapter dropdown
    /// (120x68pt), the Now Playing card's 64pt cover.
    static let thumbnail = 320

    /// `MediaCard` in `.poster` and `.square`: browse rows, library and music grids, search results.
    static let card = 640

    /// Everything 16:9 that fills a card's width: `MediaCard.landscape`, the genre, library and
    /// provider tiles (`ArtworkTile`), episode cards, Live TV program and recording tiles. Also the
    /// right width for a poster that lands in a landscape frame as a fallback, because a filled
    /// 2:3 image in a 16:9 slot is scaled by the slot's WIDTH.
    static let wideCard = 960

    /// The music cover where it is the subject: Now Playing (440pt on tvOS), the album header, and
    /// the artwork handed to `MPNowPlayingInfoCenter`. Now Playing's blurred background asks for this
    /// too, so the screen pulls one image instead of two; at a blur radius of 80 the source
    /// resolution is not observable anyway.
    static let cover = 960

    /// Profile pictures (`LayoutMetrics.profileCardSize`, 180pt on tvOS) and the person page's
    /// portrait (200pt on tvOS, 140pt at 3x on a phone, which is the 420px that sets this).
    static let avatar = 480

    /// Full-screen detail backdrop. Not derived from a tier: at 2x the tvOS point grid this would be
    /// 3840, and Jellyfin's backdrops come from TMDB at 1920 wide, so this is the source ceiling and
    /// asking for more only makes the server upscale.
    static let fullBleed = 1920

    /// Top Shelf cell art, download AND decode. The shelf is not one of our tiers, tvOS fixes the
    /// cell, so the size comes from the screen: on tvOS 26 two cells and a bit fill the 1920pt row,
    /// which puts one at around 800pt, or 1600px at the 2x the TV renders. That is twice the 404pt
    /// Apple documents for a sectioned `.hdtv` cell, and the earlier 1280 here came from the
    /// documented figure rather than from the screen.
    ///
    /// One number, not a download plus a lower decode cap. Decoding under the cell hands the shelf
    /// an image to upscale, which is what made a burned-in cell visibly softer than its remote
    /// neighbour and put two resolutions in one row (Sodalite#128). The cost lands in the
    /// extension's memory: a 1600x900 bitmap is 5.8MB, and the compositing pass holds two of them
    /// at once, which is why it stays serial.
    static let topShelfCell = 1600
}
