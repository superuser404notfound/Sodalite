import SwiftUI

/// Person-page navigation target. Jellyfin cast carries no TMDB id, and resolving one costs a round
/// trip, so the route is pushed with `tmdbID` nil and PersonDetailView resolves it behind its own
/// loading state. Resolving before the push meant a tap with no feedback at all, for as long as the
/// server took, and permanent silence when the person had no TMDB id (Sodalite#55).
struct PersonRoute: Identifiable, Hashable {
    let tmdbID: Int?
    let jellyfinPersonID: String?
    let name: String
    /// TMDB id of the title the tap came from. Not part of the identity, it only helps the person
    /// page tell two same-named TMDB people apart when it has to resolve by name (Sodalite#143).
    let sourceTMDBID: Int?
    var id: String { jellyfinPersonID ?? tmdbID.map(String.init) ?? name }

    init(tmdbID: Int? = nil, jellyfinPersonID: String? = nil, name: String, sourceTMDBID: Int? = nil) {
        self.tmdbID = tmdbID
        self.jellyfinPersonID = jellyfinPersonID
        self.name = name
        self.sourceTMDBID = sourceTMDBID
    }

    /// Route for a cast-row tap, keeping whichever id the source knows.
    init(member: CastMember, sourceTMDBID: Int? = nil) {
        self.init(
            tmdbID: member.personID,
            jellyfinPersonID: member.jellyfinPersonID,
            name: member.name,
            sourceTMDBID: sourceTMDBID
        )
    }
}

/// Map Jellyfin cast people to CastMember (Jellyfin person id stored, TMDB personID nil until tap-resolved). Capped at 15.
/// `imageWidth` comes from the caller's LayoutMetrics tier so the requested pixels track the rendered circle.
func jellyfinCastMembers(
    from people: [PersonInfo],
    imageService: JellyfinImageService,
    imageWidth: Int
) -> [CastMember] {
    people.prefix(15).map { person in
        CastMember(
            id: person.id,
            name: person.name,
            role: person.role,
            imageURL: imageService.personImageURL(
                personID: person.id,
                tag: person.primaryImageTag,
                maxWidth: imageWidth
            ),
            personID: nil,
            jellyfinPersonID: person.id
        )
    }
}

/// The detail pages' action row: one line on regular widths (tvOS, iPad), wrapping lines on compact
/// ones. Deliberately not a horizontal scroll any more: an action past the right edge is an action
/// nobody finds, which is exactly how the per-series spoiler button went unnoticed on the iPhone
/// (Sodalite#50 follow-up). Wrapping also survives the next button, a scroller only hides it.
struct DetailActionRow<Content: View>: View {
    var alignment: FlowAlignment = .leading
    var spacing: CGFloat = 16
    /// Even split across the rows the wrap needs, so six buttons read as 3+3 rather than 5+1.
    var balanced: Bool = false
    @ViewBuilder let content: () -> Content

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if hSizeClass == .compact {
                FlowLayout(alignment: alignment, spacing: spacing, balanced: balanced) {
                    content()
                }
            } else {
                HStack(spacing: spacing) {
                    content()
                }
            }
        }
        .collapsesActionButtonLabel()
    }
}

/// Two full-width baseline-aligned rows for the detail glass panels: metadata + tagline (row one), genres + studios (row two), so left/right columns sit level instead of drifting as two independent stacks (Sodalite#15 round 6 follow-up). Left cells take layout priority and never truncate; right cells get leftover width, trailing-anchored, truncate first. While detail is in flight the right cells hold skeleton bars so the panel doesn't grow when tagline/studios land. Director/writer deliberately absent (already in the cast row, and they squeezed studios out of its width).
struct DetailInfoRows<LeftPrimary: View, LeftSecondary: View>: View {
    let item: JellyfinItem
    let hasFullDetail: Bool
    /// Whether leftSecondary (the genres line) produces anything; gates the second row so an episode panel with no genres carries no invisible row spacing.
    var hasLeftSecondary: Bool = true
    /// Genres still unknown (slim row item, detail fetch in flight): reserve the genre line's height so the panel doesn't grow and push the buttons down when it lands. The skeleton bars below only cover the right column.
    var leftSecondaryPending: Bool = false
    @ViewBuilder let leftPrimary: () -> LeftPrimary
    @ViewBuilder let leftSecondary: () -> LeftSecondary

    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Whether there is any tagline / studio info to show.
    static func hasContent(_ item: JellyfinItem) -> Bool {
        let hasStudios = !(item.studios?.isEmpty ?? true)
        let hasTagline = !(item.taglines?.first?.isEmpty ?? true)
        return hasTagline || hasStudios
    }

    var body: some View {
        let tagline = item.taglines?.first
        let hasTagline = !(tagline?.isEmpty ?? true)
        let studios = studiosLine(item.studios?.map(\.name) ?? [])
        // Skeleton bars only while the right side can still gain
        // content: once the detail fetch settles empty, the rows
        // collapse to their left cells.
        let showPlaceholders = !hasFullDetail && !Self.hasContent(item)
        // The right column fills top-down: without a tagline the
        // studios move up into row one, level with the metadata line,
        // instead of dangling alone a row below it.
        let studiosInRowOne = !hasTagline && studios != nil

        if hSizeClass == .compact {
            // Phone: a single leading column with the metadata in a no-wrap horizontal scroll, so
            // values never break mid-token ("2 Std. 32 Min.") or stack vertically in the tight panel.
            VStack(alignment: .leading, spacing: 6) {
                leftPrimary()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if hasLeftSecondary {
                    leftSecondary()
                        .lineLimit(1)
                } else if leftSecondaryPending {
                    genreLinePlaceholder
                }
                if let studios {
                    styled(studios)
                } else if showPlaceholders {
                    placeholderBar(width: 140)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    leftPrimary()
                        .layoutPriority(1)
                    Spacer(minLength: 24)
                    if hasTagline, let tagline {
                        Text(tagline)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let studios {
                        styled(studios)
                    } else if showPlaceholders {
                        placeholderBar(width: 220)
                    }
                }
                if hasLeftSecondary || leftSecondaryPending || (hasTagline && studios != nil) || showPlaceholders {
                    HStack(alignment: .firstTextBaseline) {
                        leftSecondary()
                            .layoutPriority(1)
                        if !hasLeftSecondary && leftSecondaryPending {
                            genreLinePlaceholder
                        }
                        Spacer(minLength: 24)
                        if !studiosInRowOne, let studios {
                            styled(studios)
                        } else if showPlaceholders {
                            placeholderBar(width: 140)
                        }
                    }
                }
            }
        }
    }

    private func styled(_ line: Text) -> some View {
        line
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Skeleton for the genre line itself: a blank subheadline Text supplies the exact line height and baseline the real genre Text will have, the bar just draws over it.
    private var genreLinePlaceholder: some View {
        Text(verbatim: " ")
            .font(.subheadline)
            .lineLimit(1)
            .frame(width: 180, alignment: .leading)
            .overlay(alignment: .leading) { placeholderBar(width: 180) }
    }

    private func placeholderBar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.Theme.surface)
            .frame(width: width, height: 14)
    }

    private func studiosLine(_ studios: [String]) -> Text? {
        guard !studios.isEmpty else { return nil }
        // Text interpolation instead of the tvOS-26-deprecated `Text + Text`
        // concatenation; both segments keep their own styling.
        return Text("\(Text("detail.studios").fontWeight(.semibold))\(Text(verbatim: ": \(studios.prefix(3).joined(separator: ", "))"))")
    }
}
