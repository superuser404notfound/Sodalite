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

    /// The row a resumed multi-version movie draws: Play and Version labelled, the rest icon-only.
    private func movieRow(versionLabel: String) -> CGFloat {
        width(Group {
            GlassActionButton(title: "detail.resume", systemImage: "play.fill",
                              isProminent: true, subtitle: "1:23:45", action: {})
            GlassActionButton(title: "detail.version.button", systemImage: "film.stack",
                              subtitle: versionLabel, alwaysShowsLabel: true, action: {})
            GlassActionButton(title: "detail.replay", systemImage: "arrow.counterclockwise", action: {})
            GlassActionButton(title: "detail.favorite", systemImage: "heart", action: {})
            GlassActionButton(title: "detail.markWatched", systemImage: "checkmark.circle", action: {})
            GlassActionButton(title: "detail.delete.button", systemImage: "trash",
                              isDestructive: true, action: {})
        })
    }

    /// Specs only, which is what a source without a server-side name falls back to. 1166 pt measured.
    @Test func theRowFitsWithADerivedVersionLabel() {
        let w = movieRow(versionLabel: "1080p · H264 · 38,9 MB")
        #expect(w <= budget, "row is \(w) pt of \(budget)")
    }

    /// What the Merge Versions plugin produces: the version's name is the file's name, and long
    /// (Sodalite#139's own report: "Captain America The Winter Soldier (2014)"). 1394 pt measured.
    @Test func theRowFitsWithAFileNameAsTheVersionLabel() {
        let w = movieRow(versionLabel: "Captain America The Winter Soldier (2014) · 1080p · H264 · 12,4 GB")
        #expect(w <= budget, "row is \(w) pt of \(budget)")
    }

    /// A server-written label has no ceiling of its own, and a scene release name is the realistic
    /// long end of it. Unbounded that measured 2421 pt, 600 past the screen; the subtitle ceiling in
    /// `GlassActionButton` is what brings it back.
    @Test func theRowFitsWithAReleaseNameAsTheVersionLabel() {
        let w = movieRow(versionLabel: "Captain.America.The.Winter.Soldier.2014.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-FraMeSToR · 4K · HEVC · 78,4 GB")
        #expect(w <= budget, "row is \(w) pt of \(budget)")
    }

    /// However long the label grows, the row has to stop growing with it, or the actions behind it
    /// (watched, delete) walk off the right edge, where no remote press reaches them.
    @Test func theRowStopsGrowingWithTheLabel() {
        let long = movieRow(versionLabel: String(repeating: "Very Long Version Name ", count: 8))
        let longer = movieRow(versionLabel: String(repeating: "Very Long Version Name ", count: 40))
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
@MainActor
struct DetailActionRowFocusLiftTests {

    private var rowSpacing: CGFloat { DetailActionRow { EmptyView() }.spacing }

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

    /// Everything the row had before the version button is narrow enough that the cap cannot reach
    /// it: the gesture on an icon pill and on Play is the one it always was.
    @Test func aNarrowPillKeepsTheRolesOwnScale() {
        for width in [80.0, 230.0, 330.0] as [CGFloat] {
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
