import Testing
import CoreGraphics
@testable import Sodalite

struct ContentLogoBudgetTests {

    // MARK: - Tier resolution

    @Test func tvWinsOverSizeClass() {
        #expect(ContentLogoTier.tier(isTV: true, compact: true, portrait: true) == .tv)
        #expect(ContentLogoTier.tier(isTV: true, compact: false, portrait: false) == .tv)
    }

    @Test func phoneSplitsByOrientation() {
        #expect(ContentLogoTier.tier(isTV: false, compact: true, portrait: true) == .phonePortrait)
        #expect(ContentLogoTier.tier(isTV: false, compact: true, portrait: false) == .phoneLandscape)
    }

    @Test func regularIsTheTabletTier() {
        #expect(ContentLogoTier.tier(isTV: false, compact: false, portrait: true) == .regular)
        #expect(ContentLogoTier.tier(isTV: false, compact: false, portrait: false) == .regular)
    }

    // MARK: - Budget

    @Test func budgetIsAFractionOfTheMeasuredColumn() {
        let tv = ContentLogoTier.tv.budget(columnWidth: 1820)
        #expect(tv.nominalHeight == 165)
        #expect(abs(tv.maxWidth - 764.4) < 0.01)

        let portrait = ContentLogoTier.phonePortrait.budget(columnWidth: 361)
        #expect(portrait.nominalHeight == 88)
        #expect(abs(portrait.maxWidth - 288.8) < 0.01)
    }

    /// A column of 0 means geometry has not landed yet. The budget must stay usable, never collapse
    /// the mark to nothing.
    @Test func unmeasuredColumnFallsBackToTheTierNominal() {
        let budget = ContentLogoTier.regular.budget(columnWidth: 0)
        #expect(budget.maxWidth == ContentLogoTier.regular.nominalColumn * 0.55)
        #expect(budget.nominalHeight == 130)
    }

    // MARK: - Sizing

    /// A 1:1 mark is the tallest anything draws, and that is the pivot height lifted by
    /// sqrt(pivot), not the pivot height itself. Sizing it by height alone is what left squarish
    /// marks reading undersized next to wordmarks (Sodalite#97 round 2).
    @Test func stackedLogoDrawsTheCeiling() {
        let budget = ContentLogoBudget(maxWidth: 764, nominalHeight: 165)
        let size = ContentLogoSizing.size(aspect: 1, in: budget)
        #expect(abs(size.height - budget.maxHeight) < 0.001)
        #expect(abs(size.height - 244.73) < 0.01)
        #expect(abs(size.width - size.height) < 0.001)
    }

    @Test func pivotIsTheAspectThatDrawsTheNominalHeight() {
        let budget = ContentLogoBudget(maxWidth: 5000, nominalHeight: 165)
        let atPivot = ContentLogoSizing.size(aspect: ContentLogoSizing.areaPivot, in: budget)
        #expect(abs(atPivot.height - 165) < 0.001)
        let wider = ContentLogoSizing.size(aspect: ContentLogoSizing.areaPivot + 0.5, in: budget)
        #expect(wider.height < 165)
        let squarer = ContentLogoSizing.size(aspect: ContentLogoSizing.areaPivot - 0.5, in: budget)
        #expect(squarer.height > 165)
    }

    /// The whole point of the change: EVERY mark between the floor and the ceiling covers the same
    /// area, so a 6:1 wordmark, a 3:1 and a 1:1 carry the same optical weight instead of six times.
    /// Round one held this above the pivot only, which is why the squarish half read light.
    @Test func everyLogoHoldsConstantArea() {
        let budget = ContentLogoBudget(maxWidth: 100_000, nominalHeight: 165)
        let expected = ContentLogoSizing.areaPivot * 165 * 165
        for aspect in [1.0, 1.5, 2.2, 3.0, 4.5, 6.0, 8.0] as [CGFloat] {
            let size = ContentLogoSizing.size(aspect: aspect, in: budget)
            #expect(abs(size.width * size.height - expected) < 0.5)
            #expect(abs(size.width / size.height - aspect) < 0.001)
        }
    }

    /// The curve is continuous through the pivot: no step where a mark one hundredth wider than
    /// another jumps in size.
    @Test func heightFallsSmoothlyAcrossTheWholeRange() {
        let budget = ContentLogoBudget(maxWidth: 100_000, nominalHeight: 165)
        var previous = ContentLogoSizing.size(aspect: 1, in: budget).height
        for step in 1...700 {
            let aspect = 1 + CGFloat(step) * 0.01
            let height = ContentLogoSizing.size(aspect: aspect, in: budget).height
            #expect(height <= previous + 0.001)
            // The steepest the curve gets is at 1:1, about 1.2pt per hundredth of aspect. A step
            // anywhere near the old knee at 2.2 would show up here as a jump.
            #expect(previous - height < 2)
            previous = height
        }
    }

    /// The mirror of the height floor: a mark taller than it is wide stops growing rather than
    /// towering over the page, so the reserved slot has a bound.
    @Test func tallLogoStopsAtTheCeiling() {
        let budget = ContentLogoBudget(maxWidth: 100_000, nominalHeight: 165)
        for aspect in [1.0, 0.8, 0.5, 0.2] as [CGFloat] {
            let size = ContentLogoSizing.size(aspect: aspect, in: budget)
            #expect(abs(size.height - budget.maxHeight) < 0.001)
        }
    }

    @Test func bannerLogoStopsAtTheHeightFloor() {
        let budget = ContentLogoBudget(maxWidth: 100_000, nominalHeight: 100)
        let size = ContentLogoSizing.size(aspect: 20, in: budget)
        #expect(abs(size.height - 45) < 0.001)
        #expect(abs(size.width - 900) < 0.001)
    }

    @Test func widthCapWinsOverTheHeightBudget() {
        let size = ContentLogoSizing.size(aspect: 12, in: .init(maxWidth: 764, nominalHeight: 165))
        #expect(abs(size.width - 764) < 0.001)
        #expect(abs(size.height - 764.0 / 12.0) < 0.001)
    }

    /// Today's height-only cap against the budget, on the numbers from Sodalite#97: a 6:1 mark on
    /// tvOS drew 900pt wide, half the column.
    @Test func wideMarkNoLongerSprawlsAcrossTheColumn() {
        let column: CGFloat = 1820
        let size = ContentLogoSizing.size(aspect: 6, in: ContentLogoTier.tv.budget(columnWidth: column))
        #expect(size.width / column < 0.35)
        let stacked = ContentLogoSizing.size(aspect: 1, in: ContentLogoTier.tv.budget(columnWidth: column))
        #expect(abs(size.width * size.height / (stacked.width * stacked.height) - 1) < 0.01)
    }

    // MARK: - Degenerate input

    @Test func aspectIsClampedRatherThanTrusted() {
        let budget = ContentLogoBudget(maxWidth: 764, nominalHeight: 165)
        let square = ContentLogoSizing.size(aspect: 1, in: budget)
        #expect(ContentLogoSizing.size(aspect: 0, in: budget) == square)
        #expect(ContentLogoSizing.size(aspect: -3, in: budget) == square)
        #expect(ContentLogoSizing.size(aspect: .nan, in: budget) == square)
        #expect(ContentLogoSizing.size(aspect: .infinity, in: budget).width <= 764)
    }

    @Test func emptyBudgetIsEmpty() {
        #expect(ContentLogoSizing.size(aspect: 3, in: .init(maxWidth: 0, nominalHeight: 165)) == .zero)
        #expect(ContentLogoSizing.size(aspect: 3, in: .init(maxWidth: 764, nominalHeight: 0)) == .zero)
    }

    // MARK: - Pixel request

    /// The requested box must be a tier constant. Deriving it from the measured column or the
    /// decoded aspect would change the URL after the image lands, re-firing AsyncCachedImage's
    /// task(id:) and flashing the very swap this change removes.
    @Test func requestBoxIsIndependentOfColumnAndAspect() {
        let a = ContentLogoTier.tv.requestPixels(scale: 2)
        let b = ContentLogoTier.tv.requestPixels(scale: 2)
        #expect(a == b)
        #expect(a.width == Int((ContentLogoTier.tv.nominalColumn * 0.42 * 2).rounded()))
        // The ceiling, not the nominal: a 1:1 mark draws 245pt on tvOS, so 330px would be upscaled
        // by half again (Sodalite#97 round 2).
        #expect(a.height == 489)
    }

    /// A phone rotation must not move the URL: it would drop the loaded image, refetch and flash on
    /// every turn. Both phone tiers therefore share one request box.
    @Test func rotatingThePhoneDoesNotChangeTheRequest() {
        #expect(ContentLogoTier.phonePortrait.requestPoints == ContentLogoTier.phoneLandscape.requestPoints)
        #expect(ContentLogoTier.phonePortrait.requestPixels(scale: 3) == ContentLogoTier.phoneLandscape.requestPixels(scale: 3))
        // and it still covers the taller of the two budgets
        #expect(ContentLogoTier.phonePortrait.requestPoints.height
            >= ContentLogoSizing.ceiling(nominal: ContentLogoTier.phonePortrait.nominalHeight))
        #expect(ContentLogoTier.phonePortrait.requestPoints.height
            >= ContentLogoSizing.ceiling(nominal: ContentLogoTier.phoneLandscape.nominalHeight))
        #expect(ContentLogoTier.phonePortrait.requestPoints.width >= ContentLogoTier.phonePortrait.budget(columnWidth: 440).maxWidth)
    }

    @Test func requestBoxFollowsTheScale() {
        let oneX = ContentLogoTier.phonePortrait.requestPixels(scale: 1)
        let threeX = ContentLogoTier.phonePortrait.requestPixels(scale: 3)
        #expect(oneX.height == 131)
        #expect(threeX.height == 392)
        #expect(abs(threeX.width - 3 * oneX.width) <= 2)
    }
}
