import SwiftUI

/// Compact Seerr detail-header metadata line (rating, runtime, year, certification), mirroring Jellyfin's `ItemMetadataRow`; nil segments omitted.
struct SeerrMetadataRow: View {
    let rating: Double?
    let runtimeMinutes: Int?
    let year: String?
    let certification: String?
    /// Rotten Tomatoes critics score (0-100); fresh/rotten badge split at 60, matching the Jellyfin detail row.
    var rtCriticsScore: Int? = nil

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 { separator }
                segment.view
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
    }

    private struct Segment {
        let view: AnyView
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        if let rating, rating > 0, dependencies.appearancePreferences.showCommunityRating {
            out.append(Segment(view: AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(String(format: "%.1f", rating))
                }
            )))
        }
        if let rtCriticsScore, dependencies.appearancePreferences.showCriticRating {
            out.append(Segment(view: AnyView(
                HStack(spacing: 5) {
                    Image(rtCriticsScore >= 60 ? "RTFresh" : "RTRotten")
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 18)
                    Text(verbatim: "\(rtCriticsScore) %")
                }
            )))
        }
        if let runtimeMinutes, runtimeMinutes > 0 {
            out.append(Segment(view: AnyView(Text(runtimeLabel(runtimeMinutes)))))
        }
        if let year {
            out.append(Segment(view: AnyView(Text(year))))
        }
        if let certification, !certification.isEmpty {
            out.append(Segment(view: AnyView(
                Text(certification)
                    .metadataBox()
            )))
        }
        return out
    }

    private var separator: some View {
        Text("·").foregroundStyle(.secondary)
    }

    /// TMDB runtime is in minutes.
    private func runtimeLabel(_ minutes: Int) -> String {
        TimeInterval(minutes * 60).durationDisplay
    }
}
