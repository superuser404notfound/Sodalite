import Foundation

/// Names the burned-in cell artwork. Its own file in `Shared/` because the extension renders
/// against it while the tests pin it; `nonisolated` because the app targets default to MainActor
/// isolation and the extension defaults to nonisolated, and the members have to agree.
enum ResumeBarFile {

    /// Bump whenever the drawn pixels change, resolution included. It rides in the file name, so
    /// old artwork stops matching, gets swept, and re-renders; without it a look change is
    /// invisible on every cell whose progress and accent happen to be unchanged.
    nonisolated static let renderVersion = 6

    /// The progress and the accent are part of the name on purpose. The home screen caches by
    /// URL, so rewriting the same path with new pixels leaves the old bar on screen.
    nonisolated static func name(itemID: String,
                                 remote: URL,
                                 fraction: Double,
                                 accent: UInt32) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        // The access token rides in the query and rotates; keying on it would invalidate every
        // file on each rotation. The image tag is the part that actually identifies the artwork.
        let tag = URLComponents(url: remote, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tag" }?
            .value ?? "notag"
        return "bar\(renderVersion)-\(sanitized(itemID))-\(sanitized(tag))-\(percent)-\(String(format: "%06X", accent)).jpg"
    }

    nonisolated private static func sanitized(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(48))
    }
}
