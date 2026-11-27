import SwiftUI

/// How far a focused artwork leans under the thumb on the Siri Remote's touch surface (Sodalite#259).
///
/// This is our own take on the tvOS parallax, not `.hoverEffect(.highlight)`: on tvOS 26 the system
/// effect draws a thick glass rim and a strong glint that sits badly next to the flat lift and the
/// accent ring every other card wears. At rest nothing changes; the card only leans and catches a
/// faint light while the thumb moves, and settles flat again when it lifts off.
struct CardTilt: Equatable {

    /// The steepest lean, in degrees. A poster is 250 to 350 pt wide on tvOS, so this moves its edges
    /// by a few points, the same order as the focus lift itself.
    static let maxAngle: Double = 4

    /// Brightest the light gets at full lean. Zero at rest, so a focused card that is not being
    /// touched looks exactly as it did before this existed.
    static let maxSheen: Double = 0.14

    static let flat = CardTilt(x: 0, y: 0)

    /// Thumb right is positive x, thumb up is positive y, both within -1...1.
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, -1), 1)
        self.y = min(max(y, -1), 1)
    }

    /// The tilt for a pad reading, measured from where the thumb was when the card took focus.
    ///
    /// Measuring from that point is what keeps a swipe from landing on a card already leaning: the
    /// swipe that moves focus right has the pad reading far right when the new card arrives. The
    /// origin only counts while it belongs to the same touch; once the thumb has lifted (the pad
    /// recentres to exactly 0,0 and the generation moves on), the next touch starts from zero.
    static func from(reading: RemoteTouchReading, origin: RemoteTouchReading?) -> CardTilt {
        guard reading.isTouching else { return .flat }
        let base = origin.flatMap { $0.touch == reading.touch ? $0 : nil }
        return CardTilt(x: reading.x - (base?.x ?? 0), y: reading.y - (base?.y ?? 0))
    }

    /// How far off flat the card is, 0...1.
    var magnitude: Double { min((x * x + y * y).squareRoot(), 1) }

    /// Rotation about the vertical axis. Thumb right turns the right edge away from the viewer, as if
    /// the thumb pressed on that side of the card.
    var yawDegrees: Double { x * Self.maxAngle }

    /// Rotation about the horizontal axis. Thumb up turns the top edge away.
    var pitchDegrees: Double { y * Self.maxAngle }

    var sheenOpacity: Double { magnitude * Self.maxSheen }

    /// Where the light enters, in unit coordinates of the card: on the side that comes toward the
    /// viewer, which is opposite the thumb.
    var sheenStart: UnitPoint { UnitPoint(x: 0.5 - x * 0.5, y: 0.5 + y * 0.5) }
    var sheenEnd: UnitPoint { UnitPoint(x: 0.5 + x * 0.5, y: 0.5 - y * 0.5) }
}

/// One reading of the touch surface. `touch` counts touches, so a reading can tell whether it belongs
/// to the same contact as an earlier one.
struct RemoteTouchReading: Equatable {
    var x: Double = 0
    var y: Double = 0
    var touch: Int = 0

    /// The pad reports exactly 0,0 when nothing is on it. A live thumb can cross the centre too, but
    /// not land on it to the last bit for more than a passing sample, and at the centre the tilt is
    /// flat either way.
    var isTouching: Bool { x != 0 || y != 0 }
}

extension View {

    /// Leans focused artwork under the thumb on tvOS. Apply it after the artwork's overlays and its
    /// focus ring, so badges and ring lean with the picture. A no-op on iOS and macOS.
    func focusTilt(isFocused: Bool, cornerRadius: CGFloat) -> some View {
        modifier(FocusTiltModifier(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

private struct FocusTiltModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    #if os(tvOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin: RemoteTouchReading?

    func body(content: Content) -> some View {
        // Only a focused card reads the pad, so the touch stream re-renders one card and not every
        // poster on the page: Observation tracks a property only where body actually reads it.
        let tilt = isFocused && !reduceMotion
            ? CardTilt.from(reading: RemoteTouchSource.shared.reading, origin: origin)
            : .flat
        // Scoped to the lean alone, so an image that finishes loading mid-touch does not spring in.
        content
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82)) { view in
                view
                    .overlay {
                        LinearGradient(
                            colors: [.white, .white.opacity(0)],
                            startPoint: tilt.sheenStart,
                            endPoint: tilt.sheenEnd
                        )
                        .opacity(tilt.sheenOpacity)
                        .blendMode(.plusLighter)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .rotation3DEffect(.degrees(tilt.yawDegrees), axis: (x: 0, y: -1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(tilt.pitchDegrees), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            }
            .onChange(of: isFocused, initial: true) { _, focused in
                guard focused else { origin = nil; return }
                RemoteTouchSource.shared.start()
                origin = RemoteTouchSource.shared.reading
            }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
