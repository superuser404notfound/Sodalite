import SwiftUI

/// Focusable checkbox row for a season, shared by the request sheet and the admin edit sheet so the
/// two surfaces that pick seasons pick them the same way.
///
/// sodalite-ui-focus-and-tint rules: `.focusable(true)` not `Button` (the system focus chrome bleeds
/// through inside a panel over material), `.tint` stroke, tinted focused fill, activation through
/// `stableTap`.
struct SeerrSeasonRow: View {
    let title: String
    /// Pipeline state, `nil` when the season has none. Informational: it never blocks the tick, because
    /// a season deleted server-side reports stale availability and has to stay re-requestable.
    let status: SeerrMediaStatus?
    let isOn: Bool
    let toggle: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool

    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            if let status {
                Label(status.seasonLabelKey, systemImage: status.systemImage)
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isCompact ? 16 : 24)
        .padding(.vertical, isCompact ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(focused
                      ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18))
                      : AnyShapeStyle(Color.Theme.restFill))
        )
        .focusStroke(cornerRadius: 14, isFocused: focused)
        .focusableSurface(true)
        .focused($focused)
        .stableTap(isFocused: focused) { toggle() }
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }

    /// "Season 3", the same wording the edit sheet has always used.
    static func seasonTitle(_ seasonNumber: Int) -> String {
        String(
            format: String(localized: "catalog.allRequests.edit.season.format", defaultValue: "Season %d"),
            seasonNumber
        )
    }
}

extension SeerrMediaStatus {
    /// Season-scoped wording, deliberately not the title badge's: "Already available" reads as a
    /// season's own state, and `.processing` must not claim an active download, because the client
    /// cannot tell one from a request Sonarr stopped acting on long ago.
    var seasonLabelKey: LocalizedStringKey {
        switch self {
        case .available: "catalog.seasons.alreadyAvailable"
        case .processing: "catalog.status.processing"
        case .pending: "catalog.seasons.pendingApproval"
        case .partiallyAvailable: "catalog.status.partiallyAvailable"
        case .deleted: "catalog.status.removed"
        case .failed: "catalog.requestStatus.failed"
        case .unknown: "catalog.status.unknown"
        }
    }
}
