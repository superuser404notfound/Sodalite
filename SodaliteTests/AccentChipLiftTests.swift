import Testing
import UIKit
@testable import Sodalite

/// The category strip of the accent picker is a horizontal `ScrollView`, and a ScrollView clips its
/// content, so everything the focus lift adds to a chip is cut off: the top and bottom edge of every
/// chip, and the left edge of the first one. The reserve has to be at least what the lift grows.
struct AccentChipLiftTests {

    /// `AccentCategoryButton`'s label pads itself 12pt top and bottom around one line of body text.
    private var chipHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight + 24
    }

    /// A scale is applied around the centre, so each side gets half of what it adds.
    private var perSide: CGFloat { (FocusResponse.chip.scale - 1) / 2 }

    @Test("the strip reserves what the lift adds to a chip's height")
    func marginCoversTheHeight() {
        #expect(AccentPickerLayout.chipLiftMargin >= chipHeight * perSide)
    }

    /// The horizontal side is the demanding one, and it grows with the chip's text. The worst case
    /// is real and is the LAST chip, whose trailing edge is the one that hits the clip: Russian
    /// "Кинематографические" for the cinematic category, the longest of the five names across the 26
    /// shipped locales.
    @Test("the reserve covers the widest chip any locale can produce, with room to spare")
    func marginCoversTheWidestChipAnyLocaleProduces() {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let text = ("Кинематографические" as NSString).size(withAttributes: [.font: body]).width
        // The label pads itself 18pt per side and every paid category carries the crown.
        let crown = (UIImage(systemName: "crown.fill")?.size.width ?? 40) + 8
        let widest = text + 36 + crown
        // 9.6pt of it is used, so the reserve is not sized to the day's longest translation.
        #expect(AccentPickerLayout.chipLiftMargin >= widest * perSide * 1.3)
    }
}
