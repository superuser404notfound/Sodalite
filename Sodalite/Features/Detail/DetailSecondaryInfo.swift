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
    imageWidth: Int,
    serverID: String? = nil
) -> [CastMember] {
    people.prefix(15).map { person in
        CastMember(
            id: person.id,
            name: person.name,
            role: person.role,
            imageURL: imageService.personImageURL(
                personID: person.id,
                tag: person.primaryImageTag,
                maxWidth: imageWidth,
                serverID: serverID
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

/// The metadata line of the detail glass panels, with the tagline set against it on the trailing
/// edge (Sodalite#15 round 6 follow-up). Baseline-aligned so the two sit level rather than drifting
/// as independent stacks; the left cell takes layout priority and never truncates, the tagline gets
/// what is left and truncates first. While detail is in flight the right cell reserves the line so
/// the panel does not grow when the tagline lands.
///
/// Genres and studios used to sit here too, on a second row (Sodalite#146 round 2). With the
/// synopsis in the panel since round 1 they were the fourth and fifth block of text in one card,
/// and neither is what a viewer scans a detail page for. Both moved into More Details, which also
/// gave the reader on a SERIES root something to say: a series carries no media streams, so until
/// then the reader was the synopsis over again. Director and writer were never here, they are in the
/// cast row.
struct DetailInfoRows<LeftPrimary: View>: View {
    let item: JellyfinItem
    let hasFullDetail: Bool
    @ViewBuilder let leftPrimary: () -> LeftPrimary

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dependencies) private var dependencies

    /// Whether there is anything for the trailing cell to show.
    static func hasContent(_ item: JellyfinItem) -> Bool {
        !(item.taglines?.first?.isEmpty ?? true)
    }

    var body: some View {
        let wantsTagline = dependencies.appearancePreferences.showTagline
        let tagline = wantsTagline ? item.taglines?.first : nil
        let hasTagline = !(tagline?.isEmpty ?? true)
        // Reserved only while the trailing cell can still gain content: once the detail fetch
        // settles empty, or the viewer switched taglines off, the row collapses to its left cell.
        let showPlaceholder = wantsTagline && !hasFullDetail && !Self.hasContent(item)

        if hSizeClass == .compact {
            // Phone: the metadata alone, in a no-wrap horizontal scroll, so values never break
            // mid-token ("2 Std. 32 Min.") or stack vertically in the tight panel. The tagline has
            // never been drawn at this width and still is not: the column is one narrow card.
            leftPrimary()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
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
                } else if showPlaceholder {
                    placeholder
                }
            }
        }
    }

    /// Reserved, not a skeleton, and the same answer the synopsis under it has given since round 1.
    /// This used to be an opaque `surface` bar, which on a title with no tagline at all appeared at
    /// the snapshot deadline and vanished when the fetch landed: a grey block that never became
    /// anything, over a material it could not match (Sodalite#146 round 4, reported on a device).
    /// Set in the tagline's own font so what it holds open is the line that may arrive.
    private var placeholder: some View {
        Text(verbatim: " ")
            .font(.callout)
            .italic()
            .lineLimit(1)
    }
}

/// The one-line close of a detail page, after Infuse: filename, size, video codec, audio codec and
/// layout, bitrate (Sodalite#146). Not focusable, and never more than a line.
///
/// Where it is DRAWN depends on what else the page has. Normally it closes the content below the
/// fold. On a page that has nothing else down there it moves up into the first viewport instead, and
/// that is not cosmetic: see `DetailContentOverlay.hasBelowFoldContent`.
struct DetailFileCaption: View {
    let caption: String

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, metrics.rowInset)
    }
}
