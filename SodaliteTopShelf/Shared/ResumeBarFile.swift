import Foundation

/// Names the burned-in cell artwork. Its own file in `Shared/` because the extension renders
/// against it while the tests pin it; `nonisolated` because the app targets default to MainActor
/// isolation and the extension defaults to nonisolated, and the members have to agree.
enum ResumeBarFile {

    /// Bump whenever the drawn pixels change, resolution included. It rides in the file name, so
    /// old artwork stops matching, gets swept, and re-renders; without it a look change is
    /// invisible on every cell whose progress and accent happen to be unchanged.
    nonisolated static let renderVersion = 7

    /// The progress and the accent are part of the name on purpose. The home screen caches by
    /// URL, so rewriting the same path with new pixels leaves the old bar on screen.
    nonisolated static func name(itemID: String,
                                 remote: URL,
                                 fraction: Double,
                                 accent: UInt32) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        // The access token rides in the query and rotates; keying on it would invalidate every
        // file on each rotation. What identifies the picture is the rest: which item it hangs on,
        // which KIND of image it is, and the tag.
        //
        // The kind is not decoration. A Jellyfin tag is per item AND image type, so a show whose
        // Thumb and Backdrop carry the same tag is normal, and those two are different pictures:
        // measured on one series, 309KB of Thumb against 763KB of Backdrop under one tag. Keyed on
        // the tag alone, switching the artwork setting between those two handed the cell back the
        // file the other setting had rendered.
        let tag = URLComponents(url: remote, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tag" }?
            .value ?? "notag"
        return "bar\(renderVersion)-\(sanitized(itemID))-\(picture(remote))-\(sanitized(tag))"
            + "-\(percent)-\(String(format: "%06X", accent)).jpg"
    }

    /// `/Items/{owner}/Images/{kind}` as one component: the owner because parent artwork hangs on
    /// the series or the season rather than on the cell's own item, the kind because of the shared
    /// tags above.
    nonisolated private static func picture(_ remote: URL) -> String {
        let parts = remote.pathComponents
        guard let images = parts.firstIndex(of: "Images"), images > 0, images + 1 < parts.count else {
            return "nopicture"
        }
        return sanitized(parts[images - 1]) + "-" + sanitized(parts[images + 1])
    }

    nonisolated private static func sanitized(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(48))
    }
}
