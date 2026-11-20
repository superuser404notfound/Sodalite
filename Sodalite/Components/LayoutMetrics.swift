import SwiftUI

/// Platform + size-class layout knobs for the browse UI. tvOS (10-foot) keeps its
/// large values; iPad regular gets a middle tier; iPhone compact gets phone scale.
/// Card sizes are pre-cardScale; callers still multiply by appearancePreferences.cardScale.
struct LayoutMetrics: Equatable {
    var posterSize: CGSize
    /// Also the size of every 16:9 tile that is not a MediaCard (genre, provider, library):
    /// one width for the whole family, so those rows line up with a landscape media row.
    var landscapeSize: CGSize
    var squareSize: CGSize
    /// Thumbnail in the vertical detail lists (collection, playlist, watch stats).
    /// tvOS reads these from the couch, so it gets a share of the browse poster
    /// rather than the touch-scale thumb.
    var listPosterSize: CGSize
    var listTitleFont: Font
    var listOverviewFont: Font
    var rowInset: CGFloat
    var itemSpacing: CGFloat
    var rowVerticalPadding: CGFloat
    var gridMinimum: CGFloat
    var gridSpacing: CGFloat
    var gridInset: CGFloat
    var screenHInset: CGFloat
    var screenVInset: CGFloat
    var profileCardSize: CGSize
    /// Cast portrait diameter and the label column under it. These are separate because tvOS
    /// text styles are roughly double the phone's (caption1 25pt vs 12pt), so a single shared
    /// card width fits 15 characters on a phone and 8 on a TV (Sodalite#55).
    var castPortrait: CGFloat
    var castLabelWidth: CGFloat
    /// Pixel width to request for the portrait: diameter times the tier's screen scale
    /// (tvOS 4K renders 2x, iPhone 3x), so enlarging the circle can't leave the source behind.
    var castImageWidth: Int
    /// Pixels per point the tier's device draws at, and the ceiling where a family spans several
    /// devices: every iPad is 2x, iPhones are 2x or 3x, so the compact tier takes 3. It is what
    /// turns a point size here into the pixels to ask the server for, which is how `ImageWidth`
    /// is cut and what `ImageWidthTests` recomputes (Sodalite#129).
    var screenScale: CGFloat

    /// Size for a 16:9 browse tile that is not a `MediaCard`: the genre, provider and library rows.
    /// It carries `cardScale` for the reason `landscapeSize` exists at all, stated above it: these
    /// rows are stacked with a landscape media row on Home and have to line up with it. The card
    /// grew with Large Cards and the tiles did not, so the one thing the shared constant promised
    /// was the first thing the setting broke.
    func tileSize(cardScale: CGFloat) -> CGSize {
        CGSize(width: landscapeSize.width * cardScale, height: landscapeSize.height * cardScale)
    }

    /// Minimum column width for a grid of `MediaCard`s, which draw `cardScale` times their tier
    /// size. Laying the grid out against the unscaled minimum lets SwiftUI fit more columns than
    /// the cards it then draws: with Large Cards on tvOS it fitted seven 223pt columns for cards
    /// 286pt wide, so the row ran past the screen edge and every title sat on its neighbour.
    /// The minimum scales rather than being set to the card width, because the two are tuned
    /// against each other per tier (a phone deliberately runs its 120pt cards in 108pt columns to
    /// keep three of them on screen), and that relationship has to survive the setting.
    func gridColumnMinimum(cardScale: CGFloat) -> CGFloat {
        gridMinimum * cardScale
    }

    /// The same minimum for a grid of another card shape, kept in the poster's card-to-column
    /// proportion so each tier's tuning carries over.
    func gridColumnMinimum(for style: MediaCardStyle, cardScale: CGFloat) -> CGFloat {
        gridColumnMinimum(cardScale: cardScale) * size(for: style).width / posterSize.width
    }

    /// The leading edge a browse row shares with its heading, and through the rows with every
    /// other screen of the app.
    ///
    /// Beside the sidebar the rail plus its gap IS the screen margin (Sodalite#140), so a row that
    /// keeps charging its own `rowInset` on top of it starts 10pt further in than one that asks
    /// here, and two tabs then indent differently on the same TV. In the top bar, where no rail
    /// pays anything, both answers are `rowInset` and nothing moves.
    func rowLeading(shellPaysLeading: Bool) -> CGFloat {
        shellPaysLeading ? SidebarMetrics.contentLeading : rowInset
    }

    /// The same question for a screen-wide control or field, which rests on the wider screen inset
    /// rather than the row's.
    func screenLeading(shellPaysLeading: Bool) -> CGFloat {
        shellPaysLeading ? SidebarMetrics.contentLeading : screenHInset
    }

    func size(for style: MediaCardStyle) -> CGSize {
        switch style {
        case .poster: posterSize
        case .landscape: landscapeSize
        case .square: squareSize
        }
    }

    /// tvOS 10-foot tier: the current shipped values (keeps tvOS byte-identical).
    static let tv = LayoutMetrics(
        posterSize: CGSize(width: 220, height: 330),
        landscapeSize: CGSize(width: 360, height: 202),
        squareSize: CGSize(width: 220, height: 220),
        listPosterSize: CGSize(width: 140, height: 210),
        listTitleFont: .title3, listOverviewFont: .footnote,
        rowInset: 50, itemSpacing: 30, rowVerticalPadding: 20,
        gridMinimum: 220, gridSpacing: 40, gridInset: 60,
        screenHInset: 80, screenVInset: 60,
        profileCardSize: CGSize(width: 180, height: 180),
        castPortrait: 180, castLabelWidth: 220, castImageWidth: 400,
        screenScale: 2
    )
    /// iPad regular tier.
    static let regular = LayoutMetrics(
        posterSize: CGSize(width: 160, height: 240),
        landscapeSize: CGSize(width: 280, height: 158),
        squareSize: CGSize(width: 160, height: 160),
        listPosterSize: CGSize(width: 80, height: 120),
        listTitleFont: .body, listOverviewFont: .caption,
        rowInset: 28, itemSpacing: 20, rowVerticalPadding: 16,
        gridMinimum: 160, gridSpacing: 28, gridInset: 24,
        screenHInset: 40, screenVInset: 32,
        profileCardSize: CGSize(width: 160, height: 160),
        castPortrait: 120, castLabelWidth: 140, castImageWidth: 300,
        screenScale: 2
    )
    /// iPhone compact tier.
    static let compact = LayoutMetrics(
        posterSize: CGSize(width: 120, height: 180),
        landscapeSize: CGSize(width: 200, height: 112),
        squareSize: CGSize(width: 120, height: 120),
        listPosterSize: CGSize(width: 80, height: 120),
        listTitleFont: .body, listOverviewFont: .caption,
        rowInset: 16, itemSpacing: 12, rowVerticalPadding: 12,
        gridMinimum: 108, gridSpacing: 16, gridInset: 16,
        screenHInset: 16, screenVInset: 16,
        profileCardSize: CGSize(width: 120, height: 120),
        castPortrait: 100, castLabelWidth: 100, castImageWidth: 300,
        screenScale: 3
    )

    /// Platform-independent selector (testable on any target).
    static func metrics(compact: Bool, isTV: Bool) -> LayoutMetrics {
        if isTV { return .tv }
        return compact ? .compact : .regular
    }

    /// Resolves the tier for the current platform + size class.
    static func current(_ sizeClass: UserInterfaceSizeClass?) -> LayoutMetrics {
        #if os(tvOS)
        return metrics(compact: false, isTV: true)
        #else
        return metrics(compact: sizeClass == .compact, isTV: false)
        #endif
    }
}

/// Corner radius of any artwork surface (Sodalite#134).
///
/// One value, because there is no second thing for a second value to track. This shipped as 12 for
/// posters and stills against 16 for library, genre, tag and provider tiles, which looks like two
/// roles until you measure: `tileSize` IS `landscapeSize`, so a library tile and a Continue Watching
/// still are the same 360x202 surface, and on tvOS they sit on the same Home screen a scroll apart.
/// Two identically sized cards rounding differently on one screen is the drift, not a distinction.
///
/// 12 rather than 16 because that is what the surfaces a viewer sees most already wear: every
/// poster in every row and every grid, through `MediaCard`.
///
/// Deliberately not part of `LayoutMetrics`: the radius follows neither the tier nor the size. It
/// is also not the panel radius. A settings tile is chrome and rounds at 16; this is content.
enum ArtworkCorner {
    static let radius: CGFloat = 12
}
