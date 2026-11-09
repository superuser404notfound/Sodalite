import SwiftUI

/// Compact Seerr detail-header metadata line (TMDB / IMDb / RT ratings, runtime, year, certification), mirroring Jellyfin's `ItemMetadataRow`; nil segments omitted.
struct SeerrMetadataRow: View {
    let rating: Double?
    let runtimeMinutes: Int?
    let year: String?
    let certification: String?
    /// Rotten Tomatoes critics score (0-100); fresh/rotten badge split at 60, matching the Jellyfin detail row.
    var rtCriticsScore: Int? = nil
    /// IMDb rating (0-10), movies only.
    var imdbRating: Double? = nil

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
        if dependencies.appearancePreferences.showCommunityRating {
            if let rating, rating > 0 {
                out.append(Segment(view: AnyView(NamedScoreLabel(source: "TMDB", score: rating))))
            }
            if let imdbRating, imdbRating > 0 {
                out.append(Segment(view: AnyView(NamedScoreLabel(source: "IMDb", score: imdbRating))))
            }
        }
        if let rtCriticsScore, dependencies.appearancePreferences.showCriticRating {
            out.append(Segment(view: AnyView(RottenTomatoesLabel(score: rtCriticsScore, iconHeight: 18))))
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
