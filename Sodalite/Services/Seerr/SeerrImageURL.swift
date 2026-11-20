import Foundation

enum SeerrImageURL {
    private static let base = URL(string: "https://image.tmdb.org/t/p")!

    /// Drops a non-empty TMDB path's leading slash so it can be appended as a single path component. Returns nil for nil/empty input.
    private static func cleanedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    enum PosterSize: String {
        case w342, w500, w780

        /// Smallest rendition that still covers `pixelWidth`, the same rule `ImageWidth` applies to
        /// Jellyfin (Sodalite#129). A poster card is 572px at Large Cards on tvOS, which w500 does
        /// not reach, so the card asks by width rather than taking the default.
        static func covering(_ pixelWidth: Int) -> PosterSize {
            if pixelWidth <= 342 { return .w342 }
            return pixelWidth <= 500 ? .w500 : .w780
        }
    }

    enum BackdropSize: String {
        case w780, w1280
        /// The upright iPhone's 4:5 crop of a backdrop needs more than w1280's 720 rows.
        case original

        /// Smallest rendition that still covers `pixelWidth`. The 16:9 tiles reach 936px at Large
        /// Cards on tvOS, past what w780 carries.
        static func covering(_ pixelWidth: Int) -> BackdropSize {
            pixelWidth <= 780 ? .w780 : .w1280
        }
    }

    static func poster(path: String?, size: PosterSize = .w500) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    static func backdrop(path: String?, size: BackdropSize = .w1280) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    /// TMDB duotone treatment: collapses a colour logo to white-on-grey so network/studio tiles stay consistent on dark, matching Jellyseerr's CompanyCard.
    static func duotoneLogo(path: String?) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/\(cleaned)")
    }

    enum ProfileSize: String {
        case w185, h632

        /// Smallest rendition that still covers `pixelWidth`. TMDB offers nothing between the two,
        /// so anything past 185 jumps to h632 (about 421pt wide at the 2:3 profile ratio).
        static func covering(_ pixelWidth: Int) -> ProfileSize {
            pixelWidth <= 185 ? .w185 : .h632
        }
    }

    static func profile(path: String?, size: ProfileSize = .w185) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    static func logo(path: String?) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent("w92").appendingPathComponent(cleaned)
    }
}
