import Foundation
import Testing
@testable import Sodalite

@Suite("Appearance theme")
struct AppearanceThemeTests {
    @Test("catalog has three free and twenty supporter accents")
    func catalogMembership() {
        #expect(AccentPreset.allCases.filter { $0.tier == .free }.count == 3)
        #expect(AccentPreset.allCases.filter { $0.tier == .supporter }.count == 20)
        #expect(Set(AccentPreset.allCases.map(\.rawValue)).count == 23)
        for preset in AccentPreset.allCases {
            #expect(preset.category.presets.contains(preset))
        }
    }

    @Test("background catalog has two free and two supporter choices")
    func backgroundCatalogMembership() {
        #expect(BackgroundStyle.allCases.filter { $0.tier == .free }.count == 2)
        #expect(BackgroundStyle.allCases.filter { $0.tier == .supporter }.count == 2)
        #expect(BackgroundStyle.allCases.map(\.rawValue) == [
            "graphiteGlass", "oledBlack", "accentAurora", "cinemaNoir"
        ])
    }

    @Test("legacy raw identifiers resolve to approved presets", arguments: [
        ("system", AccentPreset.systemBlue),
        ("gold", .champagne),
        ("sunset", .apricot),
        ("rose", .blush),
        ("crimson", .ruby),
        ("ocean", .sky),
        ("mint", .mint),
        ("emerald", .emerald),
        ("amethyst", .royalViolet),
        ("lavender", .lavender)
    ])
    func legacyIdentifiers(raw: String, expected: AccentPreset) {
        #expect(AccentPreset(rawValue: raw) == expected)
    }

    @Test("role colors meet fixed reference contrast")
    func roleContrast() {
        let lightGlass = RGBColor(hex: 0xF2F2F7)
        let darkSurface = RGBColor(hex: 0x16181D)
        for preset in AccentPreset.allCases {
            #expect(preset.palette.navigation.contrastRatio(with: lightGlass) >= 4.5)
            #expect(preset.palette.focus.contrastRatio(with: darkSurface) >= 3.0)
            // Measured against whatever the glyph constants actually are, so trading pure black for
            // a softer near-black later has to survive this floor instead of quietly undercutting it.
            let onControl = preset.palette.foreground.contrastRatio(with: preset.palette.control)
            #expect(onControl >= 3.0, "\(preset.rawValue) draws its label at \(onControl):1")
        }
    }

    /// The catalog assertion above only proves the rule on 23 hand-picked hexes. The rule itself is
    /// a claim about every colour, and the 0.30 threshold is the whole of it: nudge it up and the
    /// fills just under the new value keep a white label that no longer clears 3:1.
    @Test("the derived foreground clears 3:1 on any fill, not just the catalog")
    func foregroundRuleHoldsOffCatalog() {
        func check(_ color: RGBColor) {
            #expect(color.legibleForeground.contrastRatio(with: color) >= 3.0,
                    "\(String(format: "%06X", color.hex)) is illegible under its own foreground")
        }
        for step in 0...255 {
            let value = UInt32(step)
            check(RGBColor(hex: value << 16 | value << 8 | value))
            check(RGBColor(hex: value << 16))
            check(RGBColor(hex: value << 8))
            check(RGBColor(hex: value))
        }
    }

    /// Sodalite#112. The Now Playing Play/Pause circle is accent-filled in both states, so the glyph
    /// is drawn on `restingControl` as often as on `control`. Darkening moves the fill AWAY from a
    /// white glyph and TOWARD a dark one, so it is the dark-glyph presets that have to be checked,
    /// and they are checked here rather than at the button, which owns no colour logic.
    @Test("the derived foreground clears 3:1 on the resting fill as well")
    func foregroundSurvivesTheRestingFill() {
        for preset in AccentPreset.allCases {
            let ratio = preset.palette.foreground.contrastRatio(with: preset.palette.restingControl)
            #expect(ratio >= 3.0, "\(preset.rawValue) draws its glyph at \(ratio):1 while unfocused")
        }
        // Same argument as the rule above: the claim is about every colour, not the 23 in the
        // catalog. Measured floor is 3.72:1, at a magenta just over the foreground threshold.
        for step in 0...255 {
            let value = UInt32(step)
            for hex in [value << 16 | value << 8 | value, value << 16, value << 8, value] {
                let color = RGBColor(hex: hex)
                let resting = color.darkened(by: AccentPalette.restingDarkening)
                #expect(color.legibleForeground.contrastRatio(with: resting) >= 3.0,
                        "\(String(format: "%06X", hex)) loses its glyph when darkened")
            }
        }
    }

    /// The other half of #112: the resting shade is the focus signal, so it has to be a real step.
    /// Indigo is the tightest at 1.363:1, and dropping the darkening to 25% would put it under this
    /// floor, which is the point. Anything that reads "focused" only because a ring is missing is
    /// not a focus state on a screen where Play/Pause is what focus lands on by default.
    @Test("the resting fill is a visible step below the accent")
    func restingFillIsAVisibleStep() {
        for preset in AccentPreset.allCases {
            let step = preset.palette.control.contrastRatio(with: preset.palette.restingControl)
            #expect(step >= 1.30, "\(preset.rawValue) only steps \(step):1 on focus")
            #expect(preset.palette.restingControl != preset.palette.control)
        }
    }

    @Test("entitlement fallback is independent per axis")
    func entitlementResolution() {
        let free = AppearanceThemeResolver.resolve(
            storedAccent: .violet,
            storedBackground: .oledBlack,
            isSupporter: false
        )
        #expect(free.accent == .violet)
        #expect(free.background == .oledBlack)

        let premiumAccent = AppearanceThemeResolver.resolve(
            storedAccent: .ultraviolet,
            storedBackground: .oledBlack,
            isSupporter: false
        )
        #expect(premiumAccent.accent == .systemBlue)
        #expect(premiumAccent.background == .oledBlack)

        let premiumBackground = AppearanceThemeResolver.resolve(
            storedAccent: .orange,
            storedBackground: .cinemaNoir,
            isSupporter: false
        )
        #expect(premiumBackground.accent == .orange)
        #expect(premiumBackground.background == .graphiteGlass)

        let supporter = AppearanceThemeResolver.resolve(
            storedAccent: .ultraviolet,
            storedBackground: .cinemaNoir,
            isSupporter: true
        )
        #expect(supporter.accent == .ultraviolet)
        #expect(supporter.background == .cinemaNoir)
    }

    @Test("background defaults to graphite and persists")
    @MainActor
    func backgroundPreference() {
        let suite = "AppearanceThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppearancePreferences(store: defaults)
        #expect(first.backgroundStyle == .graphiteGlass)
        first.backgroundStyle = .cinemaNoir

        let second = AppearancePreferences(store: defaults)
        #expect(second.backgroundStyle == .cinemaNoir)
    }

    @Test("removed crystal preference falls back to graphite")
    @MainActor
    func removedCrystalPreferenceFallback() {
        let suite = "AppearanceThemeTests.removedCrystal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("polishedCrystal", forKey: "appearance.backgroundStyle")

        let preferences = AppearancePreferences(store: defaults)

        #expect(preferences.backgroundStyle == .graphiteGlass)
    }

    @Test("categories presets and backgrounds expose localized titles")
    func localizedTitles() {
        #expect(AccentCategory.allCases.map(\.title) == [
            String(localized: "appearance.category.basic", defaultValue: "Basic"),
            String(localized: "appearance.category.pastel", defaultValue: "Pastel"),
            String(localized: "appearance.category.bold", defaultValue: "Bold"),
            String(localized: "appearance.category.electric", defaultValue: "Electric"),
            String(localized: "appearance.category.cinematic", defaultValue: "Cinematic")
        ])
        #expect(AccentPreset.allCases.map(\.title) == [
            String(localized: "appearance.accent.system", defaultValue: "System Blue"),
            String(localized: "appearance.accent.orange", defaultValue: "Orange"),
            String(localized: "appearance.accent.violet", defaultValue: "Violet"),
            String(localized: "appearance.accent.sky", defaultValue: "Sky"),
            String(localized: "appearance.accent.mint", defaultValue: "Mint"),
            String(localized: "appearance.accent.blush", defaultValue: "Blush"),
            String(localized: "appearance.accent.apricot", defaultValue: "Apricot"),
            String(localized: "appearance.accent.lavender", defaultValue: "Lavender"),
            String(localized: "appearance.accent.cobalt", defaultValue: "Cobalt"),
            String(localized: "appearance.accent.emerald", defaultValue: "Emerald"),
            String(localized: "appearance.accent.ruby", defaultValue: "Ruby"),
            String(localized: "appearance.accent.amber", defaultValue: "Amber"),
            String(localized: "appearance.accent.royalViolet", defaultValue: "Royal Violet"),
            String(localized: "appearance.accent.cyan", defaultValue: "Cyan"),
            String(localized: "appearance.accent.magenta", defaultValue: "Magenta"),
            String(localized: "appearance.accent.lime", defaultValue: "Lime"),
            String(localized: "appearance.accent.ultraviolet", defaultValue: "Ultraviolet"),
            String(localized: "appearance.accent.solarOrange", defaultValue: "Solar Orange"),
            String(localized: "appearance.accent.petrol", defaultValue: "Petrol"),
            String(localized: "appearance.accent.burgundy", defaultValue: "Burgundy"),
            String(localized: "appearance.accent.indigo", defaultValue: "Indigo"),
            String(localized: "appearance.accent.copper", defaultValue: "Copper"),
            String(localized: "appearance.accent.champagne", defaultValue: "Champagne")
        ])
        #expect(BackgroundStyle.allCases.map(\.title) == [
            String(localized: "appearance.background.graphite", defaultValue: "Graphite Glass"),
            String(localized: "appearance.background.oled", defaultValue: "OLED Black"),
            String(localized: "appearance.background.aurora", defaultValue: "Accent Aurora"),
            String(localized: "appearance.background.noir", defaultValue: "Cinema Noir")
        ])
    }
}
