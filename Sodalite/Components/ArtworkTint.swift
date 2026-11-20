import SwiftUI

/// The two ends of a page's tint: the colour directly under the hero band, and the colour the page
/// has deepened to by its bottom. Deliberately not black at the far end, the page keeps its colour
/// all the way down (Vincent, 2026-08-30).
struct ArtworkPalette: Equatable {
    var near: Color
    var far: Color

    /// Unresolved artwork. Black at both ends, so a page that has not read its image yet is simply
    /// the black the detail views already put under their ZStack, never a seam.
    static let base = ArtworkPalette(near: .black, far: .black)
}

/// What the hero artwork's bottom edge is made of: the plain average, and what the coloured pixels
/// in it agree on. Split out from the drawing so the gate below can be reasoned about, and tested,
/// without an image.
struct ArtworkStripReading: Equatable {
    /// Plain average of the strip, in HSB.
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat
    /// Hue the strip's chroma points at, as a chroma-weighted circular mean.
    var dominantHue: CGFloat
    /// Saturation of the coloured pixels alone, chroma-weighted.
    var chromaticSaturation: CGFloat
    /// How much those pixels agree on one hue, 0 (evenly spread) to 1 (single hue).
    var coherence: CGFloat
    /// Average absolute chroma, which is what says whether there is any colour to read at all.
    var chroma: CGFloat
}

/// Page tint derived from hero artwork, for the iPhone-portrait detail page.
///
/// The portrait hero is a 16:9 band that ends mid-screen; below it the page carries a colour pulled
/// from the artwork's own bottom edge, so the band dissolves into the page instead of ending on a
/// hard cut (Sodalite#95). The hue is always the artwork's own. The saturation is lifted to a floor,
/// because the page has to stay dark enough for white body text and a dark colour needs a high HSB
/// saturation before the eye reads it as a colour at all: at brightness 0.24 a saturation of 0.39
/// spans 24 of 255 levels, which is a grey with a lean. That same arithmetic is why raising the
/// saturation floor alone could not answer Sodalite#146 round 2, see `clamped`.
///
/// Measured over 22 backdrops (2026-08-31, the corpus behind Sodalite#95's tint note): 19 of them
/// have a chroma-weighted hue coherence of 0.55 or better, so the strip's hues do NOT cancel and the
/// average already points at the right hue. What made nearly every page read grey or brown was the
/// brightness clamp plus the fact that much graded content has a warm bottom edge (8 of the 22 sit at
/// hue 0.03 to 0.13, which is brown once it is dark). Lifting saturation is therefore the lever;
/// re-deriving the hue only rescues the few strips whose average is dragged off by grey pixels
/// (The Matrix: average saturation 0.045, chromatic saturation 0.435).
///
/// The lift is gated, because a strip with no colour in it must stay neutral. Two failure cases from
/// the same corpus: an achromatic backdrop (Arrival, chroma 0.000) has no hue to recover, and a
/// letterboxed one (The Lord of the Rings, chroma 0.000 under a black bar) reports a coherence of
/// 0.89 that is entirely JPEG noise. Both keep the plain average, which is grey, which is honest.
enum ArtworkTint {

    /// Cells the bottom strip is reduced to before it is measured. Wide and short, like the strip,
    /// and 512 cells is enough to separate a hue from noise while staying one draw and one pass.
    nonisolated private static let gridWidth = 64
    nonisolated private static let gridHeight = 8

    /// Below this much average chroma there is no colour in the strip to point at.
    nonisolated private static let chromaGate: CGFloat = 0.02
    /// Below this the coloured pixels disagree about which hue they are, so their mean is a hue the
    /// artwork does not have.
    nonisolated private static let coherenceGate: CGFloat = 0.55
    /// Saturation the tint is lifted to when the gate opens, and the ceiling it is held under. The
    /// ceiling is taste, not contrast: saturating a colour at a fixed HSB brightness lowers its
    /// luminance, so a stronger tint is the safer one for the overlay rather than the riskier one.
    ///
    /// The floor was 0.45 and is 0.62 (Sodalite#146 round 2, chosen at a render sheet). Raising it
    /// alone would not have answered the report, and the sheet is what showed why: at the brightness
    /// the page is held to, a saturation step spans so few levels that the whole column for a dark
    /// backdrop did not move between 0.45 and 0.62. The lever was the brightness window below.
    nonisolated private static let saturationFloor: CGFloat = 0.62
    nonisolated private static let saturationCeiling: CGFloat = 0.85
    /// Ceiling for a strip that does not pass the gate, unchanged from the first build.
    nonisolated private static let neutralSaturationCeiling: CGFloat = 0.55

    /// Reads the image's bottom eighth and clamps the result into a dark, legible page colour.
    ///
    /// The strip, not the whole image: the tint has to continue the pixels the band actually ends on,
    /// and a full-frame average of a dark-bottom/bright-top backdrop lands somewhere neither edge is.
    nonisolated static func bottomEdgePalette(of image: PlatformImage) -> ArtworkPalette? {
        guard let reading = stripReading(of: image) else { return nil }
        return palette(for: reading)
    }

    /// Measures the bottom eighth: its average, and what its coloured pixels agree on.
    nonisolated static func stripReading(of image: PlatformImage) -> ArtworkStripReading? {
        guard let source = image.cgImage, source.width > 0, source.height > 0 else { return nil }

        // CGImage crop coordinates are top-left origin, so the bottom strip starts at height - strip.
        let stripHeight = max(1, source.height / 8)
        let strip = CGRect(
            x: 0,
            y: source.height - stripHeight,
            width: source.width,
            height: stripHeight
        )
        guard let cropped = source.cropping(to: strip) else { return nil }

        // Averaging by drawing into a small grid: CoreGraphics box-filters the strip down for us, so
        // there is no per-pixel loop over the artwork and no second decode of the image. A grid
        // rather than a single pixel because one pixel can only carry the average, and the average is
        // exactly what cannot tell a grey strip from two colours cancelling.
        var pixels = [UInt8](repeating: 0, count: gridWidth * gridHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: gridWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))

        var sumRed: CGFloat = 0
        var sumGreen: CGFloat = 0
        var sumBlue: CGFloat = 0
        var hueX: CGFloat = 0
        var hueY: CGFloat = 0
        var chromaSum: CGFloat = 0
        var saturationSum: CGFloat = 0
        let cells = gridWidth * gridHeight

        for index in 0..<cells {
            let red = CGFloat(pixels[index * 4]) / 255
            let green = CGFloat(pixels[index * 4 + 1]) / 255
            let blue = CGFloat(pixels[index * 4 + 2]) / 255
            sumRed += red
            sumGreen += green
            sumBlue += blue

            let cell = hsb(red: red, green: green, blue: blue)
            // Weighting by absolute chroma is what ignores the grey pixels: a strip of dust with one
            // sunset in it points at the sunset, and a strip of dust alone weighs nothing at all.
            let chroma = max(red, green, blue) - min(red, green, blue)
            let angle = 2 * CGFloat.pi * cell.hue
            hueX += chroma * cos(angle)
            hueY += chroma * sin(angle)
            chromaSum += chroma
            saturationSum += chroma * cell.saturation
        }

        let count = CGFloat(cells)
        let mean = hsb(red: sumRed / count, green: sumGreen / count, blue: sumBlue / count)
        var dominantHue = atan2(hueY, hueX) / (2 * .pi)
        if dominantHue < 0 { dominantHue += 1 }

        return ArtworkStripReading(
            hue: mean.hue,
            saturation: mean.saturation,
            brightness: mean.brightness,
            dominantHue: dominantHue,
            chromaticSaturation: chromaSum > 0 ? saturationSum / chromaSum : 0,
            coherence: chromaSum > 0 ? hypot(hueX, hueY) / chromaSum : 0,
            chroma: chromaSum / count
        )
    }

    /// Turns a reading into the page colour: the artwork's hue, a saturation the eye can still see at
    /// this brightness, and a brightness dark enough for white text at any artwork brightness. The
    /// far end is the same colour deepened, never black.
    nonisolated static func palette(for reading: ArtworkStripReading) -> ArtworkPalette {
        let carriesColour = reading.chroma >= chromaGate && reading.coherence >= coherenceGate
        let hue = carriesColour ? reading.dominantHue : reading.hue
        let saturation: CGFloat
        if carriesColour {
            // Never below the floor, never above what the coloured pixels themselves are: the lift
            // makes the artwork's colour visible at this brightness, it does not invent a stronger one.
            let measured = max(reading.saturation, reading.chromaticSaturation * reading.coherence)
            saturation = min(max(measured, saturationFloor), saturationCeiling)
        } else {
            saturation = min(reading.saturation, neutralSaturationCeiling)
        }
        return clamped(hue: hue, saturation: saturation, brightness: reading.brightness)
    }

    /// Lifted off pure black so a dark backdrop still produces a visible transition rather than a
    /// black page, and held under a ceiling so a bright one cannot hand white text a near-white
    /// canvas.
    ///
    /// The window was 0.09 to 0.24 and is 0.12 to 0.30 (Sodalite#146 round 2, "all of my fades seem
    /// to be medium to dark, not vibrant", chosen at a render sheet). That report is about
    /// brightness even though it sounds like colour, and the window is the only lever that reaches
    /// every backdrop: a strip with little chroma has no saturation to lift at all, so the old
    /// ceiling was what made those pages read as grey.
    ///
    /// The ceiling is still the contrast bound, it has simply been measured further out. Against
    /// white body text the worst hue at 0.24 sits at 11.2:1 and at 0.30 at 8.8:1, where the
    /// requirement is 4.5:1; `everyTintClearsTheContrastTheBodyTextNeeds` holds the corners.
    nonisolated static func clamped(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> ArtworkPalette {
        let near = min(max(brightness, 0.12), 0.30)
        return ArtworkPalette(
            near: Color(hue: hue, saturation: saturation, brightness: near),
            far: Color(hue: hue, saturation: saturation, brightness: near * 0.4)
        )
    }

    /// RGB to HSB by hand: the measurement walks 512 cells, and a platform colour object would be
    /// allocated once per cell to hand back the same three numbers.
    nonisolated static func hsb(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let delta = maxComponent - minComponent
        var hue: CGFloat = 0
        if delta > 0 {
            if maxComponent == red {
                hue = (green - blue) / delta
            } else if maxComponent == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxComponent == 0 ? 0 : delta / maxComponent, maxComponent)
    }
}

/// Tints already derived, keyed by the artwork URL that produced them.
///
/// Two sibling views need the same colour (the band fades into it, the page below is painted with
/// it) and only one of them ever sees the decoded image, so the tint travels through here rather
/// than through a binding threaded across every detail screen. Keyed by URL, so a second page
/// opened over the first cannot inherit its colour.
@MainActor
@Observable
final class ArtworkTintStore {
    static let shared = ArtworkTintStore()

    private var palettes: [URL: ArtworkPalette] = [:]
    private var inFlight: Set<URL> = []

    func palette(for url: URL?) -> ArtworkPalette? {
        guard let url else { return nil }
        return palettes[url]
    }

    /// Derives and stores the tint for `url` once. Cheap (one 64x8 draw of an already decoded image),
    /// but off the main actor regardless: it runs while the detail page is painting its first frame.
    func resolve(_ image: PlatformImage, for url: URL) {
        guard palettes[url] == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            let palette = ArtworkTint.bottomEdgePalette(of: image)
            await MainActor.run {
                ArtworkTintStore.shared.inFlight.remove(url)
                if let palette {
                    ArtworkTintStore.shared.palettes[url] = palette
                }
            }
        }
    }
}
