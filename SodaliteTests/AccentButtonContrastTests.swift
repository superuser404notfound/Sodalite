import Foundation
import Testing
@testable import Sodalite

/// Sodalite#113. The label on a prominent button is not drawn on `control`, it is drawn on `control`
/// at the style's fill opacity over whatever is behind the button. That ground is bounded: the
/// action row sits on `Color.Theme.scrim` (black at 0.55), so it runs from black, under a dark
/// backdrop or none, to a 0.45 grey, under pure white artwork, and no brighter.
///
/// The point of the suite is that the derived foreground survives that composite. It is what lets
/// the button apply `AccentPalette.foreground` without recomputing the blend at the call site.
@Suite("Accent button contrast")
struct AccentButtonContrastTests {
    /// Layer blending is done in the gamma-encoded space the colours are authored in, so the
    /// composite is a straight per-channel mix, not a mix of the linearised values.
    private func composite(_ fill: RGBColor, alpha: Double, over ground: Double) -> RGBColor {
        func mix(_ channel: Double) -> UInt32 {
            UInt32((min(1, max(0, alpha * channel + (1 - alpha) * ground)) * 255).rounded())
        }
        return RGBColor(hex: mix(fill.red) << 16 | mix(fill.green) << 8 | mix(fill.blue))
    }

    /// Black backdrop, and the brightest the scrim can leave behind (white artwork under 0.55 black).
    private let grounds: [Double] = [0, 0.45]

    @Test("the derived foreground clears 3:1 on the fill as it is actually composited")
    func foregroundSurvivesTheFill() {
        let opacities = [
            GlassButtonStyle.restingFillOpacity,
            GlassButtonStyle.focusedFillOpacity
        ]
        for preset in AccentPreset.allCases {
            let foreground = preset.palette.foreground
            for alpha in opacities {
                for ground in grounds {
                    let fill = composite(preset.palette.control, alpha: alpha, over: ground)
                    let ratio = foreground.contrastRatio(with: fill)
                    #expect(ratio >= 3.0, """
                        \(preset.rawValue) at alpha \(alpha) over ground \(ground) \
                        draws its label at \(ratio):1
                        """)
                }
            }
        }
    }

    /// The bug this replaced: a white label on the same fills. Kept as a test so the numbers that
    /// motivated the change stay attached to it, and so raising the fill opacity back toward opaque
    /// cannot quietly re-enter through a preset nobody checked.
    @Test("a white label would have failed on the light accents")
    func whiteLabelWasTheDefect() {
        let failing = AccentPreset.allCases.filter { preset in
            let fill = composite(
                preset.palette.control,
                alpha: GlassButtonStyle.focusedFillOpacity,
                over: 0
            )
            return RGBColor.white.contrastRatio(with: fill) < 3.0
        }
        #expect(failing.count == 8, "expected the eight lightest presets, got \(failing.map(\.rawValue))")
        #expect(failing.allSatisfy { $0.palette.foreground == .black })
    }
}
