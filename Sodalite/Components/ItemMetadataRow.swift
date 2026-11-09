import SwiftUI

/// Shared metadata display row: year · runtime · rating badge · TMDB / IMDb or ★ score · RT · optional extras
///
/// Separators sit BETWEEN the segments that survived, not in front of each one. Written the other
/// way the row grew a leading dot as soon as everything ahead of a segment dropped out, which the
/// rating switches (Sodalite#127) turn from a rarity into an everyday case.
///
/// A dot also stands between two WORDS only. Where a neighbour draws its own border, that border is
/// the separation already, and a dot beside it lands hard against the edge instead of in a gap
/// (Sodalite#146 round 3 for the format pills, round 4 for the age rating, which is the same kind of
/// box and kept its dots because the row could not tell the two sorts of segment apart).
struct ItemMetadataRow: View {
    let item: JellyfinItem
    var showRuntime: Bool = true
    /// Segments appended after the built-in ones. A list rather than a closure so a caller with
    /// nothing to add adds nothing: a closure handing back an EmptyView is still a segment, and the
    /// row put a separator in front of it, leaving the line ending on a dot with nothing behind it.
    var extras: [AnyView] = []
    /// Bordered segments, appended last. The format pills are the case: boxes with edges, which
    /// separate themselves. Inside the run `FormatBadgeRow` already separates by spacing.
    var badges: [AnyView] = []
    /// Named scores from Jellyseerr; they replace the server's anonymous star when present.
    var externalRatings: ExternalRatings? = nil
    /// A Jellyseerr ratings fetch is still out, so the star waits for it.
    var awaitingExternalRatings: Bool = false

    @Environment(\.dependencies) private var dependencies

    /// A segment and whether it carries its own border, which is all the row needs to know to place
    /// the dots.
    private struct Segment {
        let view: AnyView
        var isBordered: Bool = false
    }

    /// Where the dots go, over the segments' borders in order. A pure function rather than a
    /// condition inside the body because it is the rule two rounds of this issue were about, and a
    /// rule is worth testing rather than grepping the body for.
    static func needsSeparator(before index: Int, bordered: [Bool]) -> Bool {
        guard index > 0, index < bordered.count else { return false }
        return !bordered[index] && !bordered[index - 1]
    }

    var body: some View {
        let all = segments
        let bordered = all.map(\.isBordered)
        HStack(spacing: 12) {
            ForEach(Array(all.enumerated()), id: \.offset) { index, segment in
                if Self.needsSeparator(before: index, bordered: bordered) { separator }
                segment.view
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
    }

    private var segments: [Segment] {
        var out: [Segment] = []

        if let year = item.productionYear {
            out.append(Segment(view: AnyView(Text(String(year)))))
        }

        // `> 0` and not just non-nil: a file the server could not probe reports RunTimeTicks 0, and
        // "0 Min." is a measurement nobody made (Sodalite#146 round 2, seen on a test file).
        if showRuntime, let runtime = item.runTimeTicks, runtime > 0 {
            out.append(Segment(view: AnyView(Text(runtime.ticksToDurationDisplay))))
        }

        if let rating = item.officialRating {
            out.append(Segment(
                view: AnyView(
                    Text(rating)
                        .metadataBox()
                ),
                isBordered: true
            ))
        }

        let ratings = RatingDisplay.resolve(
            communityRating: item.communityRating,
            criticRating: item.criticRating,
            external: externalRatings,
            awaitingExternal: awaitingExternalRatings
        )
        if dependencies.appearancePreferences.showCommunityRating {
            if let tmdb = ratings.tmdb {
                out.append(Segment(view: AnyView(NamedScoreLabel(source: "TMDB", score: tmdb))))
            }
            if let imdb = ratings.imdb {
                out.append(Segment(view: AnyView(NamedScoreLabel(source: "IMDb", score: imdb))))
            }
            if let star = ratings.community {
                out.append(Segment(view: AnyView(StarScoreLabel(score: star))))
            }
        }
        if let critic = ratings.rottenTomatoes,
           dependencies.appearancePreferences.showCriticRating {
            out.append(Segment(view: AnyView(RottenTomatoesLabel(score: critic))))
        }

        out.append(contentsOf: extras.map { Segment(view: $0) })
        out.append(contentsOf: badges.map { Segment(view: $0, isBordered: true) })

        return out
    }

    private var separator: some View {
        Text("·").foregroundStyle(.secondary)
    }
}

extension View {
    /// The bordered look of a metadata segment (age rating, format pill). The edge is drawn in the
    /// text's own style, so box and label stay one colour wherever the row puts them (Sodalite#171).
    func metadataBox() -> some View {
        font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.foreground, lineWidth: 1)
            )
    }
}
