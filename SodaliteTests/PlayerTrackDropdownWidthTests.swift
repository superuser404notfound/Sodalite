import SwiftUI
import Testing
@testable import Sodalite

/// A text dropdown sized itself to its FIRST row: the lazy stack measures only the rows it has made,
/// so a list opening on a short row ("Original", a subtitle "Off") clipped every longer one below it
/// to "Bis..." on the Apple TV (Sodalite#87, measured 257 pt against 581 pt for the same rows reversed).
@MainActor
struct PlayerTrackDropdownWidthTests {
    private func width(_ items: [DropdownItem]) -> CGFloat {
        ImageRenderer(content: PlayerTrackDropdownList(items: items)).uiImage?.size.width ?? 0
    }

    private let rows = ["Original", "Bis 40 Mbit/s (4K)", "Bis 20 Mbit/s (1080p)", "Bis 10 Mbit/s (1080p)",
                        "Bis 4 Mbit/s (720p)", "Bis 2 Mbit/s (480p)"]

    @Test func theWidestRowSetsTheWidthWhereverItSits() {
        let items = rows.enumerated().map { i, title in
            DropdownItem(title: title, isActive: i == 0, isHighlighted: i == 3,
                         hint: i >= 3 ? "Server rechnet neu" : nil)
        }
        let shortFirst = width(items)
        let longFirst = width(Array(items.reversed()))
        #expect(shortFirst > 400)
        #expect(abs(shortFirst - longFirst) < 1)
    }
}
