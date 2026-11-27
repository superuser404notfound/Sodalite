import SwiftUI

/// Read-only episode preview card in the catalog series detail; no per-episode request action since Jellyseerr's smallest request unit is a whole season.
struct SeerrEpisodeCard: View {
    let episode: SeerrEpisode
    let isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Same landscape tier the Jellyfin series detail's EpisodeCard uses, so both episode rows match on a phone.
    /// tvOS keeps its tuned catalog size rather than inheriting the (larger) browse landscape tier.
    ///
    /// Static because `CatalogDetailView` reserves this row's height while the season loads, and a
    /// reservation computed from a second copy of these numbers is one that drifts.
    static func size(compact: Bool, cardScale: CGFloat) -> CGSize {
        #if os(tvOS)
        let base = CGSize(width: 320, height: 180)
        #else
        let base = LayoutMetrics.metrics(compact: compact, isTV: false).landscapeSize
        #endif
        return CGSize(width: base.width * cardScale, height: base.height * cardScale)
    }

    private var cardSize: CGSize {
        Self.size(
            compact: hSizeClass == .compact,
            cardScale: dependencies.appearancePreferences.cardScale
        )
    }
    private var width: CGFloat { cardSize.width }
    private var imageHeight: CGFloat { cardSize.height }

    private var titleFont: Font {
        #if os(tvOS)
        .body
        #else
        .caption
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.Theme.surface
                    .frame(width: width, height: imageHeight)

                if let url = SeerrImageURL.backdrop(path: episode.stillPath, size: .covering(ImageWidth.wideCard)) {
                    AsyncCachedImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderArt
                    }
                    .frame(width: width, height: imageHeight)
                    .clipped()
                } else {
                    placeholderArt
                }

                // Episode-number chip, top-leading so it doesn't overlap the still's centre.
                VStack {
                    HStack {
                        Text("\(episode.episodeNumber)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: width, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            // Bounded for the same reason as MediaCard's poster: a fill-scaled image overflows its
            // frame, and the clip above is visual only, so the invisible part stays tappable and
            // covers the neighbour drawn before it (discussion #98).
            .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            // Focus border on the fixed-height still so it can't drift with caption-block size.
            .overlay(
                MediaFocusRing(
                    cornerRadius: ArtworkCorner.radius,
                    isFocused: isFocused
                )
            )
            .focusTilt(isFocused: isFocused, cornerRadius: ArtworkCorner.radius)

            // Both lines always render (blank subtitle falls back to a space) so cards keep equal
            // total height without a hardcoded caption reserve that wouldn't survive a size-class change.
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.name ?? "")
                    .font(titleFont)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(subtitle ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        // Not a `FocusResponse` role, and NOT the drift it looks like: this card is always built
        // inside a `FocusableCard`, which already applies `.card`, so this is a SECOND lift stacked
        // on the first (1.05 x 1.04 today). The enclosing ScrollView in CatalogDetailView budgets
        // its padding against exactly these two numbers. Collapsing the stack is a separate change
        // with a visible result, so the values stay measured-in-place here (#130).
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 14, y: 6)
        .animation(FocusResponse.settle, value: isFocused)
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "tv")
                .font(.system(size: min(36, imageHeight * 0.3)))
                .foregroundStyle(.secondary)
        }
        .frame(width: width, height: imageHeight)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let date = episode.airDate, date.count >= 4 {
            parts.append(String(date.prefix(4)))
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
