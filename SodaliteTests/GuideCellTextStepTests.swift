import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// Sodalite#137 round 2: both guide cells pick their title size from a fit test instead of scaling
/// each cell by its own fraction, so one screen carries two sizes rather than a continuum.
///
/// The fit test is the fragile half, and it fails SILENTLY in both directions: a candidate that
/// reports the height of its clamp rather than of its text always "fits", so the step never engages
/// and the title comes back on one truncated line, which looks like a data problem rather than a
/// layout one. These tests therefore render the real cell and count the lines that came out.
///
/// Measured on the tvOS simulator against real font metrics.
@MainActor
struct GuideCellTextStepTests {

    // MARK: - Rendering

    /// Vertical bands of text ink in a rendered cell, one per rendered line.
    ///
    /// `xFrom` skips the channel cell's logo, which is ink too.
    private func textBands(_ view: some View, size: CGSize, xFrom: CGFloat = 0,
                           brightness: UInt8 = 200) -> [ClosedRange<Int>] {
        // Dark, like the app. `ImageRenderer` renders light by default, which puts secondary text
        // BELOW the fill in brightness rather than above it.
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.uiImage, let cg = image.cgImage else { return [] }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<height {
            var lit = 0
            for x in Int(xFrom)..<width {
                let i = (y * width + x) * 4
                // The title is white on a dark fill and the cell's own border is not: the border
                // runs down the left and right edges, so three lit pixels in a row is a glyph.
                if pixels[i] > brightness && pixels[i + 1] > brightness
                    && pixels[i + 2] > brightness { lit += 1 }
            }
            if lit > 3 {
                if start == nil { start = y }
            } else if let s = start {
                bands.append(s...(y - 1))
                start = nil
            }
        }
        if let s = start { bands.append(s...(height - 1)) }
        // Glyph gaps inside one line (dots of an umlaut, a comma below the baseline) are not lines.
        return bands.filter { $0.count >= 6 }
    }

    private func programCell(_ title: String) -> some View {
        GuideProgramCellContent(title: title, isAiring: false, hasTimer: false,
                                isFocused: false, tint: .blue)
    }

    private func channelCell(_ name: String, number: String?) -> some View {
        GuideChannelCellContent(name: name, number: number, logoURL: nil, isFavorite: false,
                                isFocused: false, tint: .blue, metrics: .tv)
    }

    /// A 30-minute block, which is where the guide spends most of its width.
    private let halfHour = CGSize(width: 30 * GuideMetrics.tv.pointsPerMinute,
                                  height: GuideMetrics.tv.rowHeight)

    // MARK: - Program block

    @Test("a title that wraps inside the row keeps the full size")
    func aShortTitleStaysAtHeadline() {
        let bands = textBands(programCell("Die Simpsons"), size: halfHour)
        #expect(bands.count == 2)
        let ink = CGFloat((bands.last?.upperBound ?? 0) - (bands.first?.lowerBound ?? 0))
        // Ink is shorter than the lines that carry it, so the two candidates are told apart by the
        // height two stepped lines would occupy in full: full-size ink overshoots it, stepped ink
        // cannot reach it.
        let step = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        #expect(ink > 2 * step, "two lines measured \(ink) pt of ink, expected full size")
    }

    /// The regression this is here for: with the candidate clamped to two lines the fit test passes
    /// for every title, the step never engages, and a long name comes back cut at the full size.
    @Test("a title too long for two full-size lines steps down instead of losing its second half")
    func aLongTitleStepsDown() {
        let bands = textBands(programCell("Das perfekte Dinner"), size: halfHour)
        #expect(bands.count == 2)
        let ink = CGFloat((bands.last?.upperBound ?? 0) - (bands.first?.lowerBound ?? 0))
        let step = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        #expect(ink < 2 * step, "two lines measured \(ink) pt of ink, expected the step")
    }

    /// The complaint that reopened #137: the scale floor is not a second size but a continuum, and
    /// it moves the baselines with it, so two blocks side by side carried different type and
    /// different apparent padding. Measured against the old build these titles rendered at pitches
    /// of 40, 45 and 46 pt; there are two pitches now and nothing in between.
    ///
    /// The pitch is read between the tops of the two rendered lines rather than from the ink, since
    /// ink height follows the glyphs (a line of lowercase is shorter than one with a cap).
    @Test("a wrapped title renders at one of the two sizes, never between them",
          arguments: [("Das perfekte Dinner", 30), ("Law & Order: Special Victims Unit", 45),
                      ("Tagesschau", 15), ("heute journal", 30), ("Die Simpsons", 30),
                      ("Terra X: Die Macht der Vulkane", 30)])
    func aWrappedTitleUsesOneOfTwoSizes(title: String, minutes: Int) {
        let size = CGSize(width: CGFloat(minutes) * GuideMetrics.tv.pointsPerMinute,
                          height: GuideMetrics.tv.rowHeight)
        let bands = textBands(programCell(title), size: size)
        #expect(bands.count == 2, "\(title) rendered \(bands.count) lines")
        guard bands.count == 2 else { return }
        let pitch = CGFloat(bands[1].lowerBound - bands[0].lowerBound)
        let headline = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        let step = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        let off = min(abs(pitch - headline), abs(pitch - step))
        #expect(off <= 2, "\(title) rendered a line pitch of \(pitch) pt, neither \(headline) nor \(step)")
    }

    /// A title nobody can fit truncates rather than reaching for a third size.
    @Test("an unfittable title stays on the step rather than shrinking further")
    func anUnfittableTitleStopsAtTheStep() {
        let bands = textBands(programCell("The Late Show with Stephen Colbert"), size: halfHour)
        #expect(bands.count == 2)
    }

    // MARK: - Channel column

    /// `lineLimit(2)` on the name promised a second line that the row could not pay for as soon as
    /// the channel carried a number, and SwiftUI answers that with one silently truncated line. The
    /// number itself is counted by the budget test rather than here: it is secondary grey, and a
    /// threshold that catches it also catches the fill it sits on.
    @Test("a long channel name gets its second line even with a number under it")
    func aLongChannelNameWrapsAboveItsNumber() {
        let size = CGSize(width: GuideMetrics.tv.channelColumnWidth, height: GuideMetrics.tv.rowHeight)
        let logoEdge = 12 + GuideMetrics.tv.channelLogoSize + 10
        let bands = textBands(channelCell("Sky Sport Bundesliga 1 (1080p)", number: "3"),
                              size: size, xFrom: logoEdge)
        #expect(bands.count == 2, "bands \(bands)")
    }

    @Test("a short channel name keeps one full-size line")
    func aShortChannelNameStaysOnOneLine() {
        let size = CGSize(width: GuideMetrics.tv.channelColumnWidth, height: GuideMetrics.tv.rowHeight)
        let logoEdge = 12 + GuideMetrics.tv.channelLogoSize + 10
        let bands = textBands(channelCell("ZDF HD", number: "2"), size: size, xFrom: logoEdge)
        #expect(bands.count == 1, "bands \(bands)")
    }

    // MARK: - Budget

    /// Why the channel name needs a step at all: at full size the wrapped name and the number
    /// overrun the row by 20 pt. The number moved from caption to caption2 in the same change,
    /// because hosted the stepped block measured 101 pt of the 100 with the larger one and paid the
    /// overflow with the line it had just been given; `aLongChannelNameWrapsAboveItsNumber` is what
    /// pins that, since the ceiling arithmetic here is a point too optimistic to see it.
    @Test("the stepped channel block fits the row and the full-size one does not")
    func theChannelBudgetOnlyBalancesStepped() {
        func line(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style).lineHeight.rounded(.up)
        }
        let row = GuideMetrics.tv.rowHeight
        #expect(2 * line(.subheadline) + line(.caption2) <= row)
        #expect(2 * line(.headline) + line(.caption2) > row)
    }
}
