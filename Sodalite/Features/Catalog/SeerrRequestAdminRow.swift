import SwiftUI

/// Admin-queue row: vs `SeerrRequestRow` it adds the requester name + action buttons and the row itself isn't a tap target (focus lands on individual action buttons).
struct SeerrRequestAdminRow: View {
    let request: SeerrRequest
    let title: String?
    let year: String?
    let posterURL: URL?
    let onApprove: () -> Void
    let onEdit: () -> Void
    let onDecline: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            poster

            VStack(alignment: .leading, spacing: 8) {
                Text(resolvedTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    Image(systemName: typeIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let year {
                        Text("·").foregroundStyle(.tertiary)
                        Text(year).font(.caption).foregroundStyle(.secondary)
                    }
                    if request.type == .tv, let count = request.seasons?.count, count > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(count) \(seasonsLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text("#\(request.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                // Keep each token on one line; without it the narrow phone column breaks numbers
                // mid-digit ("202\n6", "#6\n7").
                .lineLimit(1)

                if let requester = request.requestedBy {
                    Text(String(
                        format: String(
                            localized: "catalog.allRequests.requestedBy",
                            defaultValue: "Requested by %@"
                        ),
                        requester.resolvedDisplayName
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                SeerrEffectiveRequestBadge(request: request)

                actionRow
                    .padding(.top, 4)
            }
            // Claim the full remaining width. A trailing Spacer() instead fought the text column for
            // space and squeezed it, truncating the metadata line while the rigid buttons overflowed
            // past the squeezed bounds (visible room to the right, yet "Film . 20... . #...").
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if request.status == .pendingApproval {
                AdminActionButton(
                    title: "catalog.allRequests.action.approve",
                    systemImage: "checkmark.circle.fill",
                    isProminent: true,
                    action: onApprove
                )
            }
            if request.status == .pendingApproval || request.status == .approved {
                AdminActionButton(
                    title: "catalog.allRequests.action.edit",
                    systemImage: "slider.horizontal.3",
                    action: onEdit
                )
            }
            if request.status == .pendingApproval {
                AdminActionButton(
                    title: "catalog.allRequests.action.decline",
                    systemImage: "xmark.circle",
                    action: onDecline
                )
            }
            AdminActionButton(
                title: "catalog.allRequests.action.delete",
                systemImage: "trash",
                isDestructive: true,
                action: onDelete
            )
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let posterURL {
            AsyncCachedImage(url: posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderPoster
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholderPoster.frame(width: 80, height: 120)
        }
    }

    private var placeholderPoster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.Theme.restFill)
            Image(systemName: typeIcon).font(.title3).foregroundStyle(.tint)
        }
    }

    private var typeIcon: String {
        switch request.type {
        case .movie: "film"
        case .tv: "tv"
        case .person, .unknown: "person"
        }
    }

    private var typeLabel: String {
        switch request.type {
        case .movie: String(localized: "catalog.request.movie", defaultValue: "Movie")
        case .tv:    String(localized: "catalog.request.tv", defaultValue: "Series")
        case .person, .unknown: ""
        }
    }

    private var seasonsLabel: String {
        String(localized: "catalog.allRequests.seasonsLabel", defaultValue: "Seasons")
    }

    private var resolvedTitle: String {
        if let title, !title.isEmpty { return title }
        switch request.type {
        case .movie: return String(localized: "catalog.request.placeholder.movie", defaultValue: "Movie")
        case .tv:    return String(localized: "catalog.request.placeholder.tv", defaultValue: "Series")
        case .person, .unknown: return ""
        }
    }
}

/// Compact admin-row action button; sodalite-ui-focus-and-tint rules: `.tint` ShapeStyle, tinted focused fill, `.focusable` over material.
private struct AdminActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool

    /// The labelled buttons don't fit four-up on a phone and wrap to one glyph per line (a tall
    /// vertical bar). Compact width collapses each to an icon-only square touch target.
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        Group {
            if isCompact {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.caption)
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundStyle)
        )
        .focusStroke(cornerRadius: 12, isFocused: focused)
        .focusResponse(.chip, isFocused: focused)
        .focusableSurface(true)
        .focused($focused)
        .stableTap(isFocused: focused) { action() }
        .accessibilityLabel(Text(title))
    }

    private var backgroundStyle: AnyShapeStyle {
        if isDestructive {
            return AnyShapeStyle(Color.Theme.destructive.opacity(focused ? 0.85 : 0.6))
        }
        if isProminent {
            let opacity = focused ? 0.9 : 0.55
            return AnyShapeStyle(TintShapeStyle.tint.opacity(opacity))
        }
        if focused {
            return AnyShapeStyle(TintShapeStyle.tint.opacity(0.25))
        }
        return AnyShapeStyle(Color.Theme.restFillStrong)
    }
}
