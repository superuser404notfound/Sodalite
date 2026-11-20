import SwiftUI

/// The pill stack itself, split out of `PosterBadgeOverlay` so it stands alone in a render sheet:
/// every term of the geometry is a share of `fontSize`, so one number moves the whole corner
/// (Sodalite#79).
struct PosterBadgePills: View {
    let pills: [String]
    let fontSize: CGFloat
    /// The viewer's own rating, on top: it is about the viewer, the pills below about the copy.
    var rating: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.2) {
            if let rating {
                ratingPill(rating)
            }
            ForEach(pills, id: \.self) { pill(Text($0)) }
        }
        .padding(fontSize * 0.35)
    }

    private func ratingPill(_ rating: Double) -> some View {
        pill(Text("\(Text(Image(systemName: "star.fill")).foregroundStyle(.tint)) \(Self.ratingText(rating))"))
            .monospacedDigit()
            .accessibilityLabel(Text(RatingPickerSheet.label(rating)))
    }

    private func pill(_ text: Text) -> some View {
        text
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * PosterBadgeMetrics.pillHorizontalPadding)
            .padding(.vertical, fontSize * PosterBadgeMetrics.pillVerticalPadding)
            .background(Color.Theme.scrim, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.Theme.hairline, lineWidth: 1))
    }

    /// "8", or "7.5" for a fractional score another client wrote.
    static func ratingText(_ rating: Double) -> String {
        rating.formatted(.number.precision(.fractionLength(0...1)))
    }
}
