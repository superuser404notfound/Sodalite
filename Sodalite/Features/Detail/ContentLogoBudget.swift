import CoreGraphics

/// Two-axis room the detail-page title logo may occupy: a fraction of the column it sits in, and
/// the tier's height. Both bounds are needed. A height alone lets the source asset's aspect ratio
/// decide how much of the page the mark covers (Sodalite#97).
struct ContentLogoBudget: Equatable {
    /// Hard cap. A mark never draws wider than this.
    var maxWidth: CGFloat
    /// Height a mark at `ContentLogoSizing.areaPivot` draws, NOT a cap: squarer marks draw taller
    /// so that every mark covers the same area, up to `maxHeight`.
    var nominalHeight: CGFloat

    /// Tallest any mark can draw, which is what a 1:1 one gets. The slot reserves this.
    var maxHeight: CGFloat { ContentLogoSizing.ceiling(nominal: nominalHeight) }
}

/// Where the logo is being drawn. Not `LayoutMetrics`: the phone wants a different budget in
/// portrait than in landscape, and that split has no meaning for any other metric in that table.
enum ContentLogoTier: Equatable {
    case tv
    case regular
    case phoneLandscape
    case phonePortrait

    static func tier(isTV: Bool, compact: Bool, portrait: Bool) -> ContentLogoTier {
        if isTV { return .tv }
        guard compact else { return .regular }
        return portrait ? .phonePortrait : .phoneLandscape
    }

    /// Nominal height, per tier: what a mark at the pivot aspect draws. One shared value was the
    /// defect: 150pt is 8% of a tvOS column and 15% of an iPad one, so no single number can be
    /// right on both.
    var nominalHeight: CGFloat {
        switch self {
        case .tv: 165
        case .regular: 130
        case .phoneLandscape: 84
        case .phonePortrait: 88
        }
    }

    /// Share of the column the mark may span. The secondary guard: once the height is normalized by
    /// aspect this binds only for banner-shaped marks and narrow columns (iPad split view, phone
    /// portrait).
    var columnFraction: CGFloat {
        switch self {
        case .tv: 0.42
        case .regular: 0.55
        case .phoneLandscape: 0.60
        case .phonePortrait: 0.80
        }
    }

    /// Widest column the tier can present, used for two things that must not depend on a live
    /// measurement: the pixel size requested from the server, and the budget on a frame where
    /// geometry has not landed yet (layout runs before AsyncCachedImage's task, so in practice the
    /// measured width is always there before an image can be drawn).
    var nominalColumn: CGFloat {
        switch self {
        case .tv: 1820          // 1920 minus 2x LayoutMetrics.tv.rowInset
        case .regular: 1310     // 12.9" iPad, landscape, full width
        case .phoneLandscape: 900
        case .phonePortrait: 408
        }
    }

    func budget(columnWidth: CGFloat) -> ContentLogoBudget {
        let column = columnWidth > 0 ? columnWidth : nominalColumn
        return ContentLogoBudget(maxWidth: column * columnFraction, nominalHeight: nominalHeight)
    }

    /// Box to ask Jellyfin for, in points, per DEVICE FAMILY rather than per tier: the two phone
    /// tiers share one box, so rotating the phone cannot change the URL. It can, and then every
    /// rotation drops `loaded`, refetches and flashes. The box covers the widest and tallest budget
    /// in its family.
    ///
    /// Constant ON PURPOSE, for the same reason: sizing the request off the measured column or the
    /// decoded aspect would move the URL after the image lands, re-firing AsyncCachedImage's
    /// `task(id:)`.
    ///
    /// The height is the tier's CEILING, not its nominal: a squarish mark draws about 1.48x the
    /// nominal, and asking for the nominal delivers a payload that has to be upscaled by that much
    /// (Sodalite#97 round 2).
    var requestPoints: CGSize {
        switch self {
        case .tv: CGSize(width: 1820 * 0.42, height: ContentLogoSizing.ceiling(nominal: 165))
        case .regular: CGSize(width: 1310 * 0.55, height: ContentLogoSizing.ceiling(nominal: 130))
        case .phoneLandscape, .phonePortrait: CGSize(width: 900 * 0.60, height: ContentLogoSizing.ceiling(nominal: 88))
        }
    }

    /// Pixel box for the request. Jellyfin fits the image inside it and keeps its aspect, so
    /// bounding both axes covers a wide mark without pulling a needlessly tall payload for a
    /// stacked one.
    func requestPixels(scale: CGFloat) -> (width: Int, height: Int) {
        let box = requestPoints
        return (
            width: Int((box.width * scale).rounded()),
            height: Int((box.height * scale).rounded())
        )
    }
}

/// Sizes a logo inside its budget, normalized for optical weight.
///
/// Height alone (what shipped before Sodalite#97) makes rendered area a direct function of the
/// source asset's aspect ratio: a 6:1 wordmark covers six times the ink of a 1:1 stacked mark at
/// the same cap. Constant area instead, across the whole range: the height is pulled back above
/// `areaPivot` and pushed up below it, so a 6:1, a 3:1 and a 1:1 mark all cover the same box.
///
/// Round one held the area constant only ABOVE the pivot and kept a flat height below it, which
/// left squarish marks reading undersized against wordmarks that a reporter judged correct
/// (Sodalite#97 round 2). Dropping that branch is what fixes it; nothing about the wide half moves.
enum ContentLogoSizing {
    /// The aspect that draws its tier's nominal height. Squarer marks draw taller, wider ones
    /// shorter, and the area is the same at every aspect between the floor and the ceiling.
    static let areaPivot: CGFloat = 2.2
    /// Height floor, as a fraction of the nominal, so a very long banner does not thin away to a line.
    static let heightFloor: CGFloat = 0.45

    /// The other end of that clamp: the height of a 1:1 mark. Anything taller than wide stops
    /// growing here rather than towering over the page, and it is what the slot has to reserve.
    static func ceiling(nominal: CGFloat) -> CGFloat { nominal * areaPivot.squareRoot() }

    static func size(aspect: CGFloat, in budget: ContentLogoBudget) -> CGSize {
        guard budget.maxWidth > 0, budget.nominalHeight > 0 else { return .zero }
        // A decode that reported nothing usable is drawn square rather than propagating a NaN into
        // a frame modifier.
        let sane = aspect.isFinite && aspect > 0 ? aspect : 1
        let a = min(max(sane, 0.2), 20)

        let normalized = budget.nominalHeight * (areaPivot / a).squareRoot()
        let height = min(max(normalized, budget.nominalHeight * heightFloor), budget.maxHeight)
        let width = height * a
        guard width > budget.maxWidth else {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: budget.maxWidth, height: budget.maxWidth / a)
    }
}
