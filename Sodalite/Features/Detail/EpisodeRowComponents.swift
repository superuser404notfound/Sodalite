import SwiftUI

/// Sub-components extracted from SeriesDetailView. SeasonTab receives the season-bar FocusState as a parameter, so nothing here reaches into the view's focus state.

// MARK: - Season Tab

struct SeasonTab: View {
    let id: String
    let name: String
    let isSelected: Bool
    var focusedID: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focusedID.wrappedValue == id }

    var body: some View {
        Button { action() } label: {
            Text(name)
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(tabBackground)
                )
        }
        .buttonStyle(SeasonTabButtonStyle())
        .focused(focusedID, equals: id)
    }

    private var tabBackground: Color {
        if isFocused { return Color.Theme.focusFill }
        if isSelected { return Color.Theme.restFill }
        return .clear
    }
}

// MARK: - Button Styles

struct EpisodeCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Stroke drawn inside EpisodeLandscapeCard so it hugs the thumbnail only, not the caption below.
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

struct SeasonTabButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Asymmetric stroke: 50ms fade-in delay, 0 fade-out. A residual wrong-tab transition slipping past the onMoveCommand prime never shows the stroke, the 50ms window lets the DispatchQueue fallback land focus on the right tab first. 50ms is sub-perceptual.
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
                    .animation(
                        isFocused
                            ? .easeIn(duration: 0.15).delay(0.05)
                            : .easeOut(duration: 0.1),
                        value: isFocused
                    )
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Episode Landscape Card

/// Loading placeholder mirroring EpisodeLandscapeCard's 360x202 thumbnail + caption lines, with one sweeping highlight.
struct EpisodeSkeletonCard: View {
    @State private var shimmer = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var cardSize: CGSize { LayoutMetrics.current(hSizeClass).landscapeSize }
    private var synopsisWidth: CGFloat { cardSize.width - 28 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.Theme.surface)
                .frame(width: cardSize.width, height: cardSize.height)
                .overlay(shimmerOverlay.clipShape(RoundedRectangle(cornerRadius: 12)))

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Theme.surface)
                    .frame(width: min(220, cardSize.width), height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Theme.surface)
                    .frame(width: min(90, cardSize.width), height: 11)
            }
            .frame(width: cardSize.width, alignment: .leading)

            // Synopsis placeholder at EpisodeSynopsisBox's three-line height so the row keeps its height on swap.
            Text(" ")
                .font(.caption)
                .lineLimit(3, reservesSpace: true)
                .frame(width: synopsisWidth, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.Theme.surface))
                .overlay(shimmerOverlay.clipShape(RoundedRectangle(cornerRadius: 12)))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                shimmer = true
            }
        }
    }

    private var shimmerOverlay: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.08), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 180)
        .offset(x: shimmer ? cardSize.width : -180)
    }
}

struct EpisodeLandscapeCard: View {
    let episode: JellyfinItem
    let imageURL: URL?

    /// The episode the page's Play button acts on, resolved by the page's own playTarget so the ring and the button cannot claim different cards.
    var isPlayTarget: Bool = false

    /// Passed explicitly (focusedEpisodeID == episode.id): @Environment(\.isFocused) in a Button label is unreliable on tvOS.
    var isFocused: Bool = false

    /// Passed explicitly so the badge live-updates from the VM override map (the immutable episode.userData wouldn't change in-session).
    var isPlayed: Bool = false

    /// Same reason as isPlayed; also the only feedback the context-menu favorite toggle has.
    var isFavorite: Bool = false

    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var cardSize: CGSize { LayoutMetrics.current(hSizeClass).landscapeSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                AsyncCachedImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.Theme.surface)
                        .overlay(
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                        )
                }
                .frame(width: cardSize.width, height: cardSize.height)
                // Sodalite#50: veiled before the clip, else the blur bleeds past the tile edge and
                // eats the focus stroke. Progress bar and badges stay sharp, they are the user's
                // own state rather than content.
                .spoilerVeil(for: episode, style: .image)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    // Outer stroke (MediaCard pattern): no inner bite, leaves the progress bar fully visible.
                    RoundedRectangle(cornerRadius: 12 + strokeWidth)
                        .strokeBorder(strokeStyle, lineWidth: strokeWidth)
                        .padding(-strokeWidth)
                        .animation(.easeInOut(duration: 0.2), value: isFocused)
                )

                if let fraction = ResumeIndicator.fraction(playedPercentage: episode.userData?.playedPercentage,
                                                           isPlayed: isPlayed) {
                    ResumeProgressBar(fraction: fraction,
                                      remaining: remainingLabel,
                                      posterWidth: LayoutMetrics.current(hSizeClass).posterSize.width)
                        .frame(width: cardSize.width, height: cardSize.height)
                }

                ArtworkStateBadges(
                    isFavorite: isFavorite,
                    isPlayed: isPlayed,
                    posterWidth: LayoutMetrics.current(hSizeClass).posterSize.width
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(width: cardSize.width, height: cardSize.height)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // No separator glyph: the accent colour is what sets the token off the title here.
                    let token = EpisodeMetadataFormatter.seasonEpisode(season: nil,
                                                                       episode: episode.indexNumber)
                    if !token.isEmpty {
                        Text(verbatim: token)
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .fontWeight(.semibold)
                    }
                    Text(episode.name)
                        .font(.caption)
                        .lineLimit(1)
                }

                if let runtime = episode.runTimeTicks {
                    // A started episode carries its remaining time on the artwork, so the total
                    // would be a second number on one card saying something else (Sodalite#99).
                    // Blank, not absent: the strip keeps even card heights that way, the same
                    // reason MediaCard always renders its subtitle slot.
                    Text(remainingLabel == nil ? runtime.ticksToDisplay : " ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: cardSize.width, alignment: .leading)
        }
    }

    /// Time left beside the resume capsule. Reads the live `isPlayed` override rather than the
    /// immutable `episode.userData`, for the same reason the badge does: marking an episode watched
    /// in the context menu has to clear the indicator without a refetch.
    private var remainingLabel: String? {
        guard !isPlayed else { return nil }
        return episode.resumeRemainingTicks?.ticksToCompactDisplay
    }

    private var stroke: EpisodeCardStroke {
        .role(isFocused: isFocused, isPlayTarget: isPlayTarget)
    }

    /// Focus takes the semantic media role, the play target a green that is neither of the two accent
    /// roles on this row (the tint on the episode token, the focus role on the ring next door).
    private var strokeStyle: AnyShapeStyle {
        switch stroke {
        case .focused: return AnyShapeStyle(appearanceTheme.palette.focus.color)
        case .playTarget: return AnyShapeStyle(Color.Theme.success.opacity(0.8))
        case .none: return AnyShapeStyle(Color.clear)
        }
    }

    private var strokeWidth: CGFloat { stroke.lineWidth }
}

// MARK: - Episode Synopsis Box

/// Navigable per-card synopsis box (mirrors ExpandableTextBox). Always reserves three lines so columns stay equal height; an overview-less episode renders non-focusable reserved space, no focusable-but-empty dead end.
struct EpisodeSynopsisBox: View {
    let episode: JellyfinItem
    let text: String
    @State private var showFullText = false
    @FocusState private var isFocused: Bool

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    private var isSpoilerHidden: Bool {
        SpoilerReveal.isHidden(episode, dependencies: dependencies, appState: appState)
    }
    /// Matches the episode card width (landscape art width minus the 14pt horizontal padding each side) so the synopsis column lines up under its card.
    private var synopsisWidth: CGFloat { LayoutMetrics.current(hSizeClass).landscapeSize.width - 28 }

    private var hasText: Bool { !text.isEmpty }

    var body: some View {
        Group {
            if hasText {
                Text(text)
            } else {
                // Visible placeholder, not an invisible spacer: an overview-less column looks broken next to filled ones (Sodalite#15). Non-focusable, nothing to expand.
                Text("detail.noDescription")
                    .italic()
            }
        }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .frame(width: synopsisWidth, alignment: .topLeading)
            // Sodalite#50: only the text is veiled, so the material and the focus stroke stay sharp.
            .spoilerVeil(for: episode, style: .text)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                // Material base for the full-bleed backdrop redesign (ExpandableTextBox rationale).
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isFocused ? Color.Theme.focusFill : .clear)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable(hasText)
            .focused($isFocused)
            .stableTap(isFocused: isFocused) {
                guard hasText else { return }
                // Sodalite#50: the first Select uncovers, the second expands as before. One reveal
                // covers this episode's still too, both resolve through the same key.
                if isSpoilerHidden {
                    SpoilerReveal.reveal(episode, dependencies: dependencies, appState: appState)
                    return
                }
                showFullText = true
            }
            .fullScreenCover(isPresented: $showFullText) {
                TextOverlay(text: text, isPresented: $showFullText)
            }
    }
}

// MARK: - Episode Row Aim

/// Which card the episode row aims at when focus enters it. Three entries read it (a move down from
/// the season bar, the one-shot redirect that catches a focus arriving from anywhere else, and the
/// return from the player), so it is one memory and one resolver rather than a rule per entry.
///
/// The memory is written on the way OUT of the row, never on the way in, else it would answer the
/// entry redirect with the card that redirect is still resolving. The player writes it too: an
/// in-session item switch happens behind the modal, and without that write the row still names the
/// episode the session was STARTED from, which is what dropped a viewer who binged 10 through 20
/// back on 10.
struct EpisodeRowAim: Equatable {
    private(set) var rememberedID: String?

    /// Focus left the row on `id`.
    mutating func focusLeft(_ id: String) {
        rememberedID = id
    }

    /// The player moved the session onto `id` (auto-advance, queue, season picker) while the row sat behind it.
    mutating func sessionMoved(to id: String) {
        rememberedID = id
    }

    /// The card an entry lands on: the remembered one while the loaded season still holds it (the
    /// filter is what makes a memory from another season fall through), else the series' current
    /// episode, else the start of the row.
    func target(in episodeIDs: [String], currentEpisodeID: String?) -> String? {
        if let rememberedID, episodeIDs.contains(rememberedID) {
            return rememberedID
        }
        if let currentEpisodeID, episodeIDs.contains(currentEpisodeID) {
            return currentEpisodeID
        }
        return episodeIDs.first
    }
}

// MARK: - Episode Card Stroke

/// What the ring around an episode card says, and how thick it is saying it.
///
/// It used to carry three meanings, two of which always landed on the same card: the page resolves
/// its play target from the selected episode first, so "selected" and "what Play does" were one
/// answer drawn twice, in two colours. Focus wins over the play target, because a ring answers "you
/// are here" before it answers "this is where Play goes".
enum EpisodeCardStroke: CaseIterable {
    case none
    case playTarget
    case focused

    static func role(isFocused: Bool, isPlayTarget: Bool) -> EpisodeCardStroke {
        if isFocused { return .focused }
        return isPlayTarget ? .playTarget : .none
    }

    var lineWidth: CGFloat {
        switch self {
        case .none: return 0
        case .playTarget: return 3
        case .focused: return 4
        }
    }
}
