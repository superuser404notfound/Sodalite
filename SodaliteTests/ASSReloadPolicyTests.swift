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
    private let missingChineseGlyph = "[swift-ass] fontselect: failed to find any fallback with glyph 0x4F60 for font: (Microsoft YaHei, 400, 0)"

    @Test("a missing Chinese glyph triggers fallback even if the English face rendered")
    func missingChineseGlyphFallsBack() {
        var policy = ASSFontFallback()
        policy.activate(generation: 1)
        let englishFallback = policy.take(message: "fontselect: (Arial, 400, 0) -> ArialMT, 0, ArialMT", generation: 1)
        let chineseFallback = policy.take(message: missingChineseGlyph, generation: 1)
        #expect(!englishFallback)
        #expect(chineseFallback)
    }

    @Test("a missing requested font or initial glyph miss may still be resolved by libass")
    func successfulSubstitutionKeepsStyling() {
        let diagnostics = [
            "fontselect: Using default font family: (Arial, 400, 0) -> Helvetica",
            "fontselect: Using default font: Arial.ttf",
            "Glyph 0x4F60 not found, selecting one more font for (Arial, 400, 0)",
            "Glyph 0x4F60 not found, broken font? Trying all charmaps",
            "fontselect: (Microsoft YaHei, 400, 0) -> PingFangSC-Regular, 0, PingFangSC-Regular",
            "unrelated parse warning"
        ]
        var policy = ASSFontFallback()
        policy.activate(generation: 1)
        for message in diagnostics {
            let shouldFallback = policy.take(message: message, generation: 1)
            #expect(!shouldFallback)
        }
        // Nonterminal messages must not consume the one-shot latch.
        let terminalFallback = policy.take(message: missingChineseGlyph, generation: 1)
        #expect(terminalFallback)
    }

    @Test("a glyph missing even after all charmaps were tried is terminal")
    func brokenFontFallsBack() {
        #expect(ASSFontFallback.isUnrenderableGlyph(
            "Glyph 0x4F60 not found in font for (BrokenFont, 400, 0)"))
    }

    @Test("many missing glyphs cause only one fallback transition")
    func failureIsLatched() {
        var policy = ASSFontFallback()
        policy.activate(generation: 1)
        let firstFailure = policy.take(message: missingChineseGlyph, generation: 1)
        let repeatedFailure = policy.take(message: missingChineseGlyph, generation: 1)
        #expect(firstFailure)
        #expect(!repeatedFailure)
    }

    @Test("late callbacks cannot disable styling after a track switch or deactivation")
    func staleCallbacksAreIgnored() {
        var policy = ASSFontFallback()
        let inactiveFailure = policy.take(message: missingChineseGlyph, generation: 1)
        policy.activate(generation: 1)
        policy.activate(generation: 2)
        let staleFailure = policy.take(message: missingChineseGlyph, generation: 1)
        let currentFailure = policy.take(message: missingChineseGlyph, generation: 2)
        policy.deactivate()
        let deactivatedFailure = policy.take(message: missingChineseGlyph, generation: 2)
        #expect(!inactiveFailure)
        #expect(!staleFailure)
        #expect(currentFailure)
        #expect(!deactivatedFailure)
    }

    @Test("the next activation can use styling again instead of changing the saved preference")
    func nextActivationResetsFailure() {
        var policy = ASSFontFallback()
        policy.activate(generation: 1)
        let firstActivationFailure = policy.take(message: missingChineseGlyph, generation: 1)
        policy.deactivate()
        policy.activate(generation: 3)
        let healthyFontFallback = policy.take(message: "fontselect: (Arial, 400, 0) -> ArialMT", generation: 3)
        let nextActivationFailure = policy.take(message: missingChineseGlyph, generation: 3)
        #expect(firstActivationFailure)
        #expect(!healthyFontFallback)
        #expect(nextActivationFailure)
    }
}
