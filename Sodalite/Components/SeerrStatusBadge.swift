import SwiftUI

struct SeerrStatusBadge: View {
    let status: SeerrMediaStatus
    var compact: Bool = false

    var body: some View {
        if compact {
            Image(systemName: status.systemImage)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(status.color, in: Circle())
        } else {
            Label {
                Text(LocalizedStringKey(status.localizationKey))
                    .font(.caption)
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: status.systemImage)
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(status.color, in: Capsule())
        }
    }
}

/// Collapses `request.status` × `request.media?.status` into one badge. Two side-by-side badges produced confusing pairs ("Completed · Downloading") and never surfaced a completed-then-deleted item (looked like an endless download).
struct SeerrEffectiveRequestBadge: View {
    let request: SeerrRequest

    var body: some View {
        Label {
            Text(LocalizedStringKey(text))
                .font(.caption)
                .fontWeight(.medium)
        } icon: {
            Image(systemName: icon)
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color, in: Capsule())
    }

    private enum Effective {
        case pending, declined, failed
        case approved, processing
        case partiallyAvailable, available
        case removed
    }

    private var effective: Effective {
        switch request.status {
        case .declined: return .declined
        case .failed: return .failed
        case .pendingApproval: return .pending
        case .completed:
            // `completed` = Sonarr/Radarr signed off; anything but available/partial means the file was removed (.removed). Only state where the API alone confidently detects a removal.
            switch request.media?.status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            default: return .removed
            }
        case .approved:
            // Trust Seerr's status as-is. An empty Sonarr queue can't be told apart from legit waiting states (unaired episodes, unreleased movie, pending search) without history we don't keep, so ambiguous cases show "downloading" (matches Seerr's UI) until reconciliation or a manual clear.
            switch request.media?.status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            case .processing: return .processing
            case .pending: return .approved
            case .deleted: return .removed
            case .failed: return .failed
            case .unknown, nil: return .processing
            }
        }
    }

    private var text: String {
        switch effective {
        case .pending: return "catalog.requestStatus.pending"
        case .declined: return "catalog.requestStatus.declined"
        case .failed: return "catalog.requestStatus.failed"
        case .approved: return "catalog.requestStatus.approved"
        case .processing: return "catalog.status.processing"
        case .partiallyAvailable: return "catalog.status.partiallyAvailable"
        case .available: return "catalog.status.available"
        case .removed: return "catalog.status.removed"
        }
    }

    private var icon: String {
        switch effective {
        case .pending: return "clock"
        case .declined: return "xmark"
        case .failed: return "exclamationmark.triangle"
        case .approved: return "checkmark"
        case .processing: return "arrow.triangle.2.circlepath"
        case .partiallyAvailable: return "circle.lefthalf.filled"
        case .available: return "checkmark.circle.fill"
        case .removed: return "trash"
        }
    }

    private var color: Color {
        switch effective {
        case .pending: return .orange
        case .declined: return .red
        case .failed: return .red
        case .approved: return .green
        case .processing: return .blue
        case .partiallyAvailable: return .teal
        case .available: return .green
        case .removed: return .gray
        }
    }
}
