import SwiftUI

/// The scores a detail page fetched from Jellyseerr for a library title: TMDB's vote average, IMDb's
/// rating (movies only, Seerr has no IMDb source for series) and the Tomatometer.
struct ExternalRatings: Equatable, Sendable {
    var tmdb: Double?
    var imdb: Double?
    var rottenTomatoes: Int?
}

/// What the metadata line draws. TMDB and IMDb are named; `community` is the server's anonymous star,
/// whose source depends on the server's metadata provider (TMDB by default, IMDb with OMDb), so it
/// only stands in when no named score is there.
struct RatingDisplay: Equatable {
    var tmdb: Double?
    var imdb: Double?
    var community: Double?
    var rottenTomatoes: Int?

    /// `awaitingExternal`: a Seerr fetch is still out. The star holds back meanwhile, because when the
    /// named scores land it would vanish again, and swapping a segment out reads worse than one appearing.
    static func resolve(
        communityRating: Double?,
        criticRating: Double?,
        external: ExternalRatings?,
        awaitingExternal: Bool
    ) -> RatingDisplay {
        let tmdb = external?.tmdb.flatMap { $0 > 0 ? $0 : nil }
        let imdb = external?.imdb.flatMap { $0 > 0 ? $0 : nil }
        let named = tmdb != nil || imdb != nil
        return RatingDisplay(
            tmdb: tmdb,
            imdb: imdb,
            community: (named || awaitingExternal) ? nil : communityRating.flatMap { $0 > 0 ? $0 : nil },
            rottenTomatoes: criticRating.map { Int($0) } ?? external?.rottenTomatoes
        )
    }
}

/// "TMDB 7.8" / "IMDb 7.6": the source as a bold label in front of the score, in the row's own colour
/// (the metadata line is one colour, Sodalite#171). Text rather than the brands' logo artwork.
struct NamedScoreLabel: View {
    let source: String
    let score: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: source)
                .font(.caption.weight(.heavy))
            Text(String(format: "%.1f", score))
        }
    }
}

/// The server's anonymous star score.
struct StarScoreLabel: View {
    let score: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(String(format: "%.1f", score))
        }
    }
}

/// Tomatometer with the jellyfin-web fresh/rotten artwork, split at 60.
struct RottenTomatoesLabel: View {
    let score: Int
    var iconHeight: CGFloat = 20

    var body: some View {
        HStack(spacing: 5) {
            Image(score >= 60 ? "RTFresh" : "RTRotten")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(height: iconHeight)
            Text(verbatim: "\(score) %")
        }
    }
}
