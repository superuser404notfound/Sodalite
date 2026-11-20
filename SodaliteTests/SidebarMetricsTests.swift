import Testing
import CoreGraphics
import SwiftUI
@testable import Sodalite

/// Sodalite#140. The 76pt pitch is measured off the system sidebar, so it is the fixed point:
/// everything else is derived from it and a retune of the icon or the padding must not move it.
struct SidebarMetricsTests {

    @Test("the spacing is derived so the measured pitch survives a retune")
    func pitchIsTheFixedPoint() {
        #expect(SidebarMetrics.rowPitch == 76)
        #expect(SidebarMetrics.itemHeight + SidebarMetrics.itemSpacing == SidebarMetrics.rowPitch)
        #expect(SidebarMetrics.itemSpacing > 0, "a bigger icon than the pitch allows would collapse the gap")
    }

    @Test("the collapsed rail costs exactly the icon plus its own padding, no leftover white space")
    func collapsedIsAsNarrowAsItsIcon() {
        let padding = SidebarMetrics.itemHorizontalPadding(isExpanded: false)
        #expect(SidebarMetrics.collapsedWidth == SidebarMetrics.iconColumn + padding * 2)
        // Square around the icon, so the focus pill is a tile rather than a stretched capsule.
        #expect(padding == SidebarMetrics.itemVerticalPadding)
    }

    /// The first attempt at this used .title3 and guessed its size. On tvOS 26 title3 is 48pt, not
    /// the ~29 a phone habit suggests, so "Einstellungen" was truncated on device. The row uses
    /// .headline (38pt) now, and the budget is checked against that measured number.
    @Test("the label budget fits the longest label at the size the row actually uses")
    func expandedFitsTheLongestLabel() {
        let headlinePointSize: CGFloat = 38
        // Mixed-case Latin averages about half the point size per character; "Einstellungen" is 13.
        let longestLabelWidth = 13 * headlinePointSize * 0.5
        #expect(SidebarMetrics.labelWidthBudget >= longestLabelWidth)
        // And the size it replaced would NOT have fitted, which is why this test exists.
        #expect(SidebarMetrics.labelWidthBudget < 13 * 48 * 0.5)
    }

    /// The eye checks whether the gap from the screen edge to the rail matches the gap from the
    /// rail to the content. Two numbers drifting apart is what "the spacing is off" means here.
    @Test("the content sits as far from the rail as the rail sits from the screen edge")
    func theTwoGapsMatch() {
        #expect(SidebarMetrics.contentLeading == SidebarMetrics.railLeadingInset)
    }

    /// 16pt shipped once and still clipped the focused settings card. A settings tile is
    /// screen-wide and FocusResponse.tile scales it 1.03, so it grows far more per side than a
    /// media card does, and the leading margin is what it grows into.
    @Test("the leading margin swallows the focus lift of a screen-wide tile")
    func marginCoversTheWidestFocusLift() {
        let tileScale: CGFloat = 1.03
        let contentWidth: CGFloat = 1920 - SidebarMetrics.railSlot
        let growthPerSide = contentWidth * (tileScale - 1) / 2
        #expect(SidebarMetrics.contentLeading >= growthPerSide)
    }

    /// A ScrollView clips to its own bounds, so a row that pays its whole margin as padding inside
    /// it clips at the content's leading edge, which beside the rail is the rail. The margin is
    /// split so the clip line moves off it without the first card moving with it.
    @Test("a scrolling row is clipped clear of the rail, and the first card still fits")
    func rowClipsClearOfTheRail() {
        #expect(SidebarMetrics.rowClipLeading > 0, "a clip line on the rail is the defect this fixes")
        #expect(
            SidebarMetrics.rowClipLeading + SidebarMetrics.rowFocusOverhang == SidebarMetrics.contentLeading,
            "the two halves ARE the margin: a split that does not add up moves the first card"
        )
    }

    /// The half that stays inside the scroll view is what the first card, which rests against it,
    /// grows into when it takes focus. Measured against the widest tile a row can hold.
    @Test("what stays inside the scroll view covers the widest tile's focus overhang")
    func overhangCoversTheWidestTile() {
        let scale = FocusResponse.card.scale
        let widest = LayoutMetrics.tv.landscapeSize.width * AppearancePreferences.largeCardScale
        let lift = widest * (scale - 1) / 2
        let ring = MediaFocusRing<RoundedRectangle>.outset * scale
        #expect(SidebarMetrics.rowFocusOverhang >= lift + ring)
    }

    @Test("expanding is the only thing that changes the width")
    func widthFollowsExpansion() {
        #expect(SidebarMetrics.width(isExpanded: false) == SidebarMetrics.collapsedWidth)
        #expect(SidebarMetrics.width(isExpanded: true) == SidebarMetrics.expandedWidth)
    }

    @Test("the panel is wider than its rows, so a focused pill never meets the glass edge")
    func panelInsetsTheRows() {
        #expect(SidebarMetrics.panelHorizontalPadding > 0)
        #expect(SidebarMetrics.panelWidth(isExpanded: true) == SidebarMetrics.expandedWidth + SidebarMetrics.panelHorizontalPadding * 2)
        #expect(SidebarMetrics.railSlot == SidebarMetrics.railLeadingInset + SidebarMetrics.panelWidth(isExpanded: false))
    }

    @Test("the whole block fits the tvOS title-safe band, profile header included")
    func blockFitsTheBand() {
        // 1080 minus the 60pt safe inset top and bottom.
        let band: CGFloat = 960
        // Today's worst case: every optional tab present, so all six, plus the divider.
        #expect(SidebarMetrics.blockHeight(itemCount: 6, hasProfileHeader: true) <= band)
        // Headroom for the eleven rows the proposal imagines, so the geometry does not have to be
        // rethought if that ever lands.
        #expect(SidebarMetrics.blockHeight(itemCount: 11, hasProfileHeader: true) <= band)
    }
}
