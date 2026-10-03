import SwiftUI

/// The pill stack itself, split out of `PosterBadgeOverlay` so it stands alone in a render sheet:
/// every term of the geometry is a share of `fontSize`, so one number moves the whole corner
/// (Sodalite#79).
struct PosterBadgePills: View {
    let pills: [String]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.2) {
            ForEach(pills, id: \.self, content: pill)
        }
        .padding(fontSize * 0.35)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * PosterBadgeMetrics.pillHorizontalPadding)
            .padding(.vertical, fontSize * PosterBadgeMetrics.pillVerticalPadding)
            .background(Color.Theme.scrim, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.Theme.hairline, lineWidth: 1))
    }
}
