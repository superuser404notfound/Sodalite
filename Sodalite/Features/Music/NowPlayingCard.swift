import SwiftUI

/// Pill "now playing" card atop the Music tab while a track is active. Replaced the old global
/// floating mini-player (it covered detail-view action buttons). Fills with a tinted progress bar
/// (like the Resume button), shows live elapsed/total; tapping opens the fullscreen player (where
/// transport lives, so the card has no buttons).
struct NowPlayingCard: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @FocusState private var cardFocused: Bool

    var body: some View {
        let coordinator = dependencies.musicPlaybackCoordinator
        if let item = coordinator.currentItem {
            cardContent(coordinator: coordinator, item: item)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func cardContent(coordinator: MusicPlaybackCoordinator, item: JellyfinItem) -> some View {
        let progress: Double = coordinator.duration > 0
            ? min(max(coordinator.currentTime / coordinator.duration, 0), 1)
            : 0

        HStack(spacing: hSizeClass == .compact ? 14 : 24) {
            coverArt(item: item)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(cardFocused ? .white : Color.primary)
                    .lineLimit(1)

                if let artist = item.trackArtistLine {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(cardFocused ? Color.white.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(MusicTimeFormatter.string(coordinator.currentTime)) / \(MusicTimeFormatter.string(coordinator.duration))")
                .font(.caption)
                .foregroundStyle(cardFocused ? Color.white.opacity(0.9) : Color.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, hSizeClass == .compact ? 18 : 28)
        .padding(.vertical, 16)
        .background(progressFill(progress))
        .focusStroke(Capsule(), isFocused: cardFocused)
        // Not a `FocusResponse` role: the cover casts a RESTING shadow that focus deepens, where
        // every role here goes from no shadow to one. Its 1.01 is the album art's own step (#130).
        .scaleEffect(cardFocused ? 1.01 : 1.0)
        .shadow(color: .black.opacity(cardFocused ? 0.35 : 0.15), radius: 18, y: 6)
        .focusableSurface(true)
        .focused($cardFocused)
        .animation(.easeInOut(duration: 0.15), value: cardFocused)
        .stableTap(isFocused: cardFocused) {
            coordinator.requestNowPlayingPresentation()
        }
    }

    /// Material capsule with a left-anchored tinted progress fill (mirrors the Resume button).
    private func progressFill(_ progress: Double) -> some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.tint.opacity(0.3))
                        .frame(width: geo.size.width * CGFloat(progress))
                }
            }
            .clipShape(Capsule())
    }

    private func coverArt(item: JellyfinItem) -> some View {
        let coverURL = dependencies.jellyfinImageService.musicCoverURL(for: item, maxWidth: ImageWidth.thumbnail)

        return AsyncCachedImage(url: coverURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle()
                .fill(.white.opacity(0.1))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                )
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
    }
}
