import Testing
@testable import Sodalite

/// Sodalite#234: every reload reparses the whole growing script, so events far ahead of the
/// playhead wait in the builder instead of costing a parse every 5 s.
struct ASSReloadPolicyTests {
    private func due(start: Double, playhead: Double = 100, since: Double) -> Bool {
        ASSRenderCoordinator.reloadIsDue(earliestPendingStart: start, playhead: playhead,
                                         sinceLastReload: since, imminentLead: 10, reloadLead: 30,
                                         imminentSpacing: 0.25, batchSpacing: 5)
    }

    @Test("an imminent event reloads after the short spacing")
    func imminent() {
        #expect(due(start: 105, since: 0.3))
        #expect(!due(start: 105, since: 0.1))
        #expect(due(start: 90, since: 0.3))
    }

    @Test("an event inside the lead reloads on the batch spacing")
    func insideLead() {
        #expect(due(start: 125, since: 5))
        #expect(!due(start: 125, since: 4))
    }

    @Test("an event beyond the lead waits, however long ago the last reload was")
    func beyondLead() {
        #expect(!due(start: 190, since: 600))
        #expect(!due(start: .infinity, since: 600))
    }
}

struct ASSFontFallbackTests {
    private func fallbackFailure(_ codepoint: String) -> String {
        "[swift-ass] fontselect: failed to find any fallback with glyph 0x\(codepoint) for font: (Microsoft YaHei, 400, 0)"
    }

    @Test("a Chinese line no font covers switches the track to plain text")
    func missingChineseLineFallsBack() {
        var policy = ASSFontFallback()
        let english = policy.take(message: "fontselect: (Arial, 400, 0) -> ArialMT, 0, ArialMT")
        let results = ["4F60", "597D", "4E16", "754C", "4E2D"].map { policy.take(message: fallbackFailure($0)) }
        #expect(!english)
        #expect(results == [false, false, false, false, true])
    }

    @Test("messages libass recovers from never count")
    func successfulSubstitutionKeepsStyling() {
        let diagnostics = [
            "fontselect: Using default font family: (Arial, 400, 0) -> Helvetica, 0, Helvetica",
            "fontselect: Using default font: (Arial, 400, 0) -> Arial.ttf, 0, ArialMT",
            "Glyph 0x4F60 not found, selecting one more font for (Arial, 400, 0)",
            "Glyph 0x4F60 not found, broken font? Trying all charmaps",
            "fontselect: (Microsoft YaHei, 400, 0) -> PingFangSC-Regular, 0, PingFangSC-Regular",
            "unrelated parse warning"
        ]
        for message in diagnostics {
            #expect(ASSFontFallback.unrenderableCodepoint(message) == nil)
        }
    }

    @Test("both terminal libass messages yield the character")
    func terminalMessagesParse() {
        #expect(ASSFontFallback.unrenderableCodepoint(fallbackFailure("4F60")) == 0x4F60)
        #expect(ASSFontFallback.unrenderableCodepoint(
            "Glyph 0x1F3B5 not found in font for (BrokenFont, 400, 0)") == 0x1F3B5)
    }

    @Test("a few stray characters no font has keep the styling")
    func strayGlyphsKeepStyling() {
        var policy = ASSFontFallback()
        let stray = [
            fallbackFailure("E000"),
            fallbackFailure("E000"),
            "Glyph 0x2605 not found in font for (Sign, 400, 0)",
            fallbackFailure("1F3B5"),
            fallbackFailure("E001"),
        ].map { policy.take(message: $0) }
        #expect(stray == [false, false, false, false, false])
    }

    @Test("the switch fires once per renderer, however many characters follow")
    func failureIsLatched() {
        var policy = ASSFontFallback()
        let results = (0..<8).map { policy.take(message: fallbackFailure(String(0x4E00 + $0, radix: 16))) }
        #expect(results == [false, false, false, false, true, false, false, false])
    }

    @Test("a new renderer starts with a fresh count")
    func freshRendererCountsAgain() {
        let first = ASSGlyphFailures()
        let fired = ["4F60", "597D", "4E16", "754C", "4E2D"].map { first.take(message: fallbackFailure($0)) }
        let next = ASSGlyphFailures()
        let nextFirst = next.take(message: fallbackFailure("4F60"))
        #expect(fired.last == true)
        #expect(!nextFirst)
    }
}
