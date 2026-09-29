import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// The tvOS detail action row is a plain HStack of fixed-size pills: it cannot scroll, wrap or
/// compress, so whatever it adds up to is what it takes, and the overflow leaves the screen in
/// silence. Sodalite#139 put a permanently labelled button in it carrying a label the SERVER writes
/// (a media source name is a file name), which is the one string in that row nobody here controls.
///
/// Measured on the tvOS simulator against real font metrics, hosted rather than estimated.
@MainActor
struct DetailActionRowWidthTests {

    /// 1920 pt screen less the detail page's `LayoutMetrics.rowInset` on both sides.
    private let budget: CGFloat = 1920 - 2 * 50

    private func width(_ content: some View) -> CGFloat {
        let host = UIHostingController(rootView: DetailActionRow { content })
        host.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)).width
    }

    /// The row a resumed multi-version movie draws, as finished by Sodalite#146 (More Details after
    /// Watched). Play is labelled, the rest icon-only. The version pill collapses with them at rest
    /// and opens on focus (Sodalite#172); `versionFocused` stands in for that focus, which a hosted
    /// view never receives, by lifting the row's collapse off that one pill.
    private func movieRow(versionLabel: String, versionFocused: Bool) -> CGFloat {
        width(Group {
            GlassActionButton(title: "detail.resume", systemImage: "play.fill",
                              isProminent: true, subtitle: "1:23:45", action: {})
            GlassActionButton(title: "detail.version.button", systemImage: "film.stack",
                              subtitle: versionLabel, action: {})
                .environment(\.collapsesActionButtonLabel, !versionFocused)
            GlassActionButton(title: "detail.replay", systemImage: "arrow.counterclockwise", action: {})
            GlassActionButton(title: "detail.favorite", systemImage: "heart", action: {})
            GlassActionButton(title: "detail.markWatched", systemImage: "checkmark.circle", action: {})
            GlassActionButton(title: "detail.moreDetails", systemImage: "info.circle", action: {})
            GlassActionButton(title: "detail.delete.button", systemImage: "trash",
                              isDestructive: true, action: {})
        })
    }

    /// At rest the version pill is a glyph like its neighbours, so what the server named the
    /// version costs the row nothing until the pill has focus.
    @Test func atRestTheVersionLabelCostsTheRowNothing() {
        let short = movieRow(versionLabel: "1080p", versionFocused: false)
        let long = movieRow(versionLabel: String(repeating: "Very Long Version Name ", count: 8),
                            versionFocused: false)
        #expect(short == long, "resting row grew from \(short) to \(long) pt")
        #expect(short <= budget, "row is \(short) pt of \(budget)")
    }

    /// What the pill carries on focus in the common case: the words the versions do not share.
    @Test func theRowFitsWithADistinguishingLabel() {
        let w = movieRow(versionLabel: "2160p Remux", versionFocused: true)
        #expect(w <= budget, "row is \(w) pt of \(budget)")
    }

    /// Specs only, which is what versions without telling names fall back to.
    @Test func theRowFitsWithADerivedVersionLabel() {
        let w = movieRow(versionLabel: "1080p · H264 · 38,9 MB", versionFocused: true)
        #expect(w <= budget, "row is \(w) pt of \(budget)")
    }

    /// The last fallback is the full label, and a server-written label has no ceiling of its own.
    /// A scene release name is the realistic long end; unbounded it measured 2421 pt, 600 past the
    /// screen, and the subtitle ceiling in `GlassActionButton` is what brings it back.
    @Test func theRowFitsWithAReleaseNameAsTheVersionLabel() {
        let w = movieRow(versionLabel: "Captain.America.The.Winter.Soldier.2014.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-FraMeSToR · 4K · HEVC · 78,4 GB",
                         versionFocused: true)
        #expect(w <= budget, "row is \(w) pt of \(budget)")
    }

    /// However long the label grows, the focused row has to stop growing with it, or the actions
    /// behind it (watched, delete) walk off the right edge, where no remote press reaches them.
    @Test func theRowStopsGrowingWithTheLabel() {
        let long = movieRow(versionLabel: String(repeating: "Very Long Version Name ", count: 8),
                            versionFocused: true)
        let longer = movieRow(versionLabel: String(repeating: "Very Long Version Name ", count: 40),
                              versionFocused: true)
        #expect(long == longer, "row grew from \(long) to \(longer) pt")
        #expect(long <= budget, "row is \(long) pt of \(budget)")
    }

    /// The ceiling exists for labels nobody here controls. The short subtitles that were in the row
    /// before it must measure exactly as they did, so a resume stamp still sets its own width.
    @Test func theCeilingLeavesShortSubtitlesAlone() {
        let withStamp = width(GlassActionButton(title: "detail.resume", systemImage: "play.fill",
                                                isProminent: true, subtitle: "1:23:45", action: {}))
        let without = width(GlassActionButton(title: "detail.resume", systemImage: "play.fill",
                                              isProminent: true, action: {}))
        #expect(withStamp > without, "stamp added \(withStamp - without) pt")
    }
}

/// The row's other geometry: the focus lift is a SCALE, so the distance it moves an edge grows with
/// the control it is applied to. A row of siblings 16 pt apart can only afford so much of that, and
/// Sodalite#139 put a pill in it whose width a server-written label decides (Sodalite#139: at the
/// role's 1.08 a 723 pt version pill grew 29 pt per side and sat on both neighbours).
///
/// Sodalite#146 round 2 is what set the ceiling's actual value. A cap that merely fits inside the
/// gap still lets every pill eat a different share of it, and that is what a reporter sees.
@MainActor
struct DetailActionRowFocusLiftTests {

    private var rowSpacing: CGFloat { DetailActionRow { EmptyView() }.spacing }

    /// Per-side growth of a focused pill of this width, which is the number every case here is about.
    private func lift(_ width: CGFloat) -> CGFloat {
        let response = FocusResponse.pill.capped(toLift: GlassButtonStyle.liftCeiling, width: width)
        return width * (response.scale - 1) / 2
    }

    /// The row's real pill widths: a bare icon pill measured against live font metrics, then the
    /// labelled ones from the suite above.
    private var rowPillWidths: [CGFloat] {
        let host = UIHostingController(
            rootView: DetailActionRow {
                GlassActionButton(title: "detail.favorite", systemImage: "heart", action: {})
            }
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        host.view.layoutIfNeeded()
        let iconPill = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                    height: CGFloat.greatestFiniteMagnitude)).width
        return [iconPill, 495, 723, 1149]
    }

    /// The two numbers that must not drift apart: a lift wider than the gap covers the neighbour.
    @Test func theCeilingFitsInsideTheRowsSpacing() {
        #expect(GlassButtonStyle.liftCeiling <= rowSpacing)
    }

    /// Measured widths from the suite above: the version pill runs to 723 pt with a file name on it.
    @Test func aWidePillLiftsNoFurtherThanTheCeiling() {
        for width in [495.0, 723.0, 1149.0] as [CGFloat] {
            let response = FocusResponse.pill.capped(toLift: GlassButtonStyle.liftCeiling, width: width)
            let perSide = width * (response.scale - 1) / 2
            #expect(perSide <= GlassButtonStyle.liftCeiling + 0.001,
                    "a \(width) pt pill grows \(perSide) pt per side")
        }
    }

    /// The point of the ceiling's value, and the defect it closes: whichever control in the row has
    /// focus, the gap it leaves its neighbour is the same. At the old 14 the cap only bound on the
    /// wide pills, so an icon pill left 13.4 pt of the 16 and Play left 2, an 11 pt spread across
    /// one row (Sodalite#146 round 2, "the spacing ... should be consistent").
    @Test func everyPillInTheRowLeavesTheSameGap() {
        let gaps = rowPillWidths.map { rowSpacing - lift($0) }
        let spread = (gaps.max() ?? 0) - (gaps.min() ?? 0)
        #expect(spread <= 2, "gaps \(gaps) spread \(spread) pt")
    }

    /// The other half of the same report: the focused pill grows around its centre, so the FIRST one
    /// hangs past the page's left margin, where the logo, the panel and every heading below line up.
    /// Play is auto-focused, so that overhang is the page's resting state, not a transient.
    @Test func theLeadingPillBarelyLeavesTheMargin() {
        // Play with a resume stamp, the widest the primary action gets.
        #expect(lift(495) <= 4.001, "leading pill hangs \(lift(495)) pt past the margin")
    }

    /// A pill narrow enough that the role's own percentage never reaches the ceiling keeps it. Below
    /// that width a fixed distance would be a scale of its own, which is what this file argues
    /// against in the other direction.
    @Test func aPillTooNarrowForTheCeilingKeepsTheRolesOwnScale() {
        for width in [40.0, 80.0] as [CGFloat] {
            #expect(FocusResponse.pill.capped(toLift: GlassButtonStyle.liftCeiling, width: width).scale
                    == FocusResponse.pill.scale, "at \(width) pt")
        }
    }

    /// Before the control has measured itself there is nothing to cap against, and a lift of zero
    /// would read as a pill that ignores the first focus it gets.
    @Test func anUnmeasuredPillKeepsTheRolesOwnScale() {
        #expect(FocusResponse.pill.capped(toLift: GlassButtonStyle.liftCeiling, width: 0).scale
                == FocusResponse.pill.scale)
    }
}
