import SwiftUI

/// Source-neutral cast member so Jellyfin and Seerr detail views share one row. `personID` is the TMDB id used for filmography navigation; nil disables the tap.
struct CastMember: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
    let personID: Int?
    /// Jellyfin person id (resolved to TMDB on tap); nil for Seerr-sourced cast, which set `personID` directly.
    let jellyfinPersonID: String?
}

extension CastMember {
    /// The same person's next credit folded into this one: the jobs join, the first entry keeps the
    /// rest, and a portrait that hangs on the later credit is picked up rather than dropped.
    func mergingCredit(_ other: CastMember) -> CastMember {
        var jobs: [String] = []
        for job in [role, other.role] {
            let trimmed = job?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty,
                  !jobs.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { continue }
            jobs.append(trimmed)
        }
        return CastMember(
            id: id,
            name: name,
            role: jobs.isEmpty ? nil : jobs.joined(separator: ", "),
            imageURL: imageURL ?? other.imageURL,
            personID: personID ?? other.personID,
            jellyfinPersonID: jellyfinPersonID ?? other.jellyfinPersonID
        )
    }
}

extension Array where Element == CastMember {
    /// One card per person. The row identifies its cards by person id, and a repeated id makes
    /// SwiftUI's ForEach "give undefined results", measured on tvOS 26 as a slot that holds its
    /// space and draws nothing (Big Buck Bunny, whose writer also directed it, so Jellyfin sends
    /// him twice under one id). Other update paths break differently: the row keeping the previous
    /// item's cast, or staying empty. TMDB does the same for an actor credited with two characters.
    ///
    /// Caps, filters and the server's order stay the caller's business, so this only folds the
    /// repeats into the place their first credit already holds.
    func mergingDuplicatePeople() -> [CastMember] {
        var merged: [CastMember] = []
        var positionByID: [String: Int] = [:]
        for member in self {
            if let position = positionByID[member.id] {
                merged[position] = merged[position].mergingCredit(member)
            } else {
                positionByID[member.id] = merged.count
                merged.append(member)
            }
        }
        return merged
    }
}

/// Horizontal strip of cast portraits; `onSelect` nil makes the cards non-interactive.
struct MediaCastRow: View {
    /// nil suppresses the built-in heading, for callers that draw their own section header.
    var title: LocalizedStringKey? = "detail.cast"
    let members: [CastMember]
    /// Overrides the tier's row inset so the row can line up with a host screen that insets differently.
    var inset: CGFloat? = nil
    var onSelect: ((CastMember) -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var rowInset: CGFloat { inset ?? metrics.rowInset }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal, rowInset)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                // Top-aligned: a two-line role (or a member with no role at all) makes cards
                // differ in height, and centering would push their portraits out of line.
                LazyHStack(alignment: .top, spacing: metrics.itemSpacing) {
                    ForEach(members.mergingDuplicatePeople()) { member in
                        MediaCastCard(
                            member: member,
                            portrait: metrics.castPortrait,
                            labelWidth: metrics.castLabelWidth,
                            onSelect: onSelect.map { cb in { cb(member) } }
                        )
                    }
                }
                .padding(.horizontal, rowInset)
                // The focused card grows around its centre and the scroll view clips whatever
                // leaves its bounds. A 276pt tvOS card overshoots 6.9pt per side at 1.05, so the
                // tier's row padding has to carry it; the flat 12pt here cut the ring off the top
                // of the enlarged portrait (Sodalite#55 device round).
                .padding(.vertical, metrics.rowVerticalPadding)
            }
            .focusSectionCompat()
        }
    }
}

private struct MediaCastCard: View {
    let member: CastMember
    let portrait: CGFloat
    let labelWidth: CGFloat
    var onSelect: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            AsyncCachedImage(url: member.imageURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Text(initials)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: portrait, height: portrait)
            .clipShape(Circle())
            // Bounded for the same reason as MediaCard's poster: a fill-scaled image overflows its
            // frame, and the clip above is visual only, so the invisible part stays tappable and
            // covers the neighbour drawn before it (discussion #98).
            .contentShape(Circle())
            .overlay(
                MediaFocusRing(
                    shape: Circle(),
                    isFocused: isFocused
                )
            )

            VStack(spacing: 2) {
                // Four of the 24 measured cast names still overrun the tvOS label at 25pt;
                // shrinking those beats an ellipsis after seven characters.
                Text(member.name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let role = member.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: labelWidth)
        }
        // Own shadow: a 180pt circular portrait does not carry a rectangular card's r20/y10 throw.
        .focusResponse(.card.withShadow(opacity: 0.3, radius: 10, y: 5), isFocused: isFocused)
        .focusable()
        .focused($isFocused)
        .stableTap(isFocused: isFocused) { onSelect?() }
    }

    private var initials: String {
        let parts = member.name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(member.name.prefix(2)).uppercased()
    }
}
