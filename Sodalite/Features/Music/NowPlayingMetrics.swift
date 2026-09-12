import CoreGraphics

/// Layout metrics for the Now Playing screen, in one place because the wide column has to FIT.
///
/// On tvOS the cover, the title block, the transport row and the scrubber share the 960pt title-safe
/// band, and their sum was over it (967pt with a one-line album title, 1033 with a wrapped one).
/// SwiftUI paid for the overflow by taking the album title's second line away, so "In the Court of
/// the Crimson King" rendered as "In the Court of the...". The numbers below are the budget that
/// keeps the column inside the band with room to spare; `NowPlayingVerticalBudgetTests` adds them up
/// against the real tvOS font metrics, so an oversized control fails there instead of on a TV.
enum NowPlayingMetrics {

    /// What the wide tier has vertically on a 1080p tvOS screen once `contentVPadding` is off both ends.
    static let tvSafeBandHeight: CGFloat = 1080 - 2 * 60

    // MARK: - Cover

    static func coverSide(compact: Bool) -> CGFloat {
        if compact { return 280 }
        #if os(tvOS)
        return 440
        #else
        return 360
        #endif
    }

    // MARK: - Column widths

    /// Beside the queue. Narrow on purpose: the queue owns the rest of the screen.
    static var wideColumnWidth: CGFloat {
        #if os(tvOS)
        return 560
        #else
        return 400
        #endif
    }

    /// Alone, which is also the only arrangement where the title block sits in this column. The extra
    /// width is what keeps a normal album title on one line, and a wrapped title costs a whole 68pt
    /// line of the budget: of nine sample titles six wrapped at 560pt, four at 720pt.
    static var soloColumnWidth: CGFloat {
        #if os(tvOS)
        return 720
        #else
        return 560
        #endif
    }

    /// Horizontal gap between the cover column and the queue column.
    static var wideSpacing: CGFloat {
        #if os(tvOS)
        return 80
        #else
        return 48
        #endif
    }

    // MARK: - Vertical rhythm

    /// Cover to title block to chrome.
    static let columnSpacing: CGFloat = 28
    /// Inside the title block.
    static let metadataSpacing: CGFloat = 12
    /// Transport row to scrubber.
    static let chromeSpacing: CGFloat = 24

    // MARK: - Transport

    static let transportPrimary: CGFloat = 84
    static let transportSecondary: CGFloat = 64
    static let transportSpacing: CGFloat = 24

    // MARK: - Scrubber

    /// Track container. Sized for the 24pt scrubbing knob, matching the video player's own bar.
    static let scrubTrackHeight: CGFloat = 22
    /// Track to the time labels.
    static let scrubLabelSpacing: CGFloat = 10

    // MARK: - Wide-tier fit (Sodalite#142)

    /// Narrowest queue column still worth showing beside the cover. Under this the rows are all
    /// ellipsis, and the stacked layout says more with the same pixels.
    static let queueMinimumWidth: CGFloat = 200

    /// Transport row plus scrubber, the block the wide column carries under the cover. The label line
    /// is reserved generously on purpose: this figure decides whether the column FITS, and a column
    /// that overflows takes the close button off the screen with it.
    static var chromeBlockHeight: CGFloat {
        transportPrimary + chromeSpacing + scrubTrackHeight + scrubLabelSpacing + scrubLabelReserve
    }

    /// Room kept for the elapsed / remaining line under the scrubber.
    static let scrubLabelReserve: CGFloat = 30

    /// Smallest container the wide two-column layout fits in, summed from the metrics the layout
    /// itself uses.
    ///
    /// The wide tier is chosen by SIZE, not by size class. An iPhone Plus / Max in landscape reports a
    /// REGULAR width class with 440pt of height, 185 short of the column, and the page then grows past
    /// the screen: the ZStack centres the overflow and the close button, an overlay on that same
    /// stack, leaves the screen with it. That is Sodalite#142, "no way out of Now Playing".
    static func wideMinimumSize(coverSide: CGFloat,
                                columnWidth: CGFloat,
                                spacing: CGFloat,
                                hPadding: CGFloat,
                                vPadding: CGFloat) -> CGSize {
        CGSize(width: 2 * hPadding + columnWidth + spacing + queueMinimumWidth,
               height: 2 * vPadding + coverSide + columnSpacing + chromeBlockHeight)
    }

    /// The running platform's own minimum, from the same numbers the layout reads.
    static var wideMinimumSize: CGSize {
        wideMinimumSize(coverSide: coverSide(compact: false),
                        columnWidth: wideColumnWidth,
                        spacing: wideSpacing,
                        hPadding: contentHPadding(compact: false),
                        vPadding: contentVPadding(compact: false))
    }

    // MARK: - Page insets

    static func contentHPadding(compact: Bool) -> CGFloat {
        if compact { return 20 }
        #if os(tvOS)
        return 80
        #else
        return 40
        #endif
    }

    static func contentVPadding(compact: Bool) -> CGFloat {
        if compact { return 24 }
        #if os(tvOS)
        return 60
        #else
        return 40
        #endif
    }
}
