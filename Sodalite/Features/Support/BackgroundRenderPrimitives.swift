import SwiftUI

/// A gradient stop expressed as opacity over a single tint, so the falloff
/// can be reasoned about and tested without materialising a `Color`.
struct SoftGradientStop: Equatable {
    let opacity: Double
    let location: Double
}

extension Array where Element == SoftGradientStop {
    func gradientStops(
        _ color: Color,
        intensity: Double = 1
    ) -> [Gradient.Stop] {
        map {
            Gradient.Stop(
                color: color.opacity($0.opacity * intensity),
                location: $0.location
            )
        }
    }
}

/// Shared noise tile. Cinema Noir uses it as visible film grain, Accent
/// Aurora as a dither that breaks up 8 bit banding in its wide gradients.
enum BackgroundGrain {
    static let filmOpacity: Double = 0.045
    static let ditherOpacity: Double = 0.03

    static let image: PlatformImage = {
        var seed: UInt64 = 0x534F44414C495445
        func next() -> UInt8 {
            seed = 6364136223846793005 &* seed &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 40)
        }
        return PlatformImage.drawn(size: CGSize(width: 96, height: 96)) { context in
            for y in 0..<96 {
                for x in 0..<96 {
                    let value = CGFloat(next()) / 255
                    context.setFillColor(CGColor(gray: value, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()
}

/// Always compose this above every other layer. Dithering only helps when it
/// is applied after the last compositing step that can quantise a gradient.
///
/// The texture never moves. Grain that drifts slowly enough to be followed
/// reads as a crawling pattern rather than as grain, which is far more
/// distracting behind static content than holding it still.
struct BackgroundGrainLayer: View {
    let opacity: Double

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(platformImage: BackgroundGrain.image), scale: 1))
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}
