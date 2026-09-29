import SwiftUI

/// The format pills on a detail page's metadata line (Sodalite#145): resolution, dynamic range,
/// audio codec, and how big the sound is, which is the spatial format where there is one and the
/// channel layout everywhere else (Sodalite#160).
///
/// Same shape as the age-rating box two segments to the left, so the
/// line reads as one row rather than as a row with a badge strip stapled onto it.
///
/// Text, not the brand artwork the request arrived with: the Dolby Vision, Dolby Atmos, DTS:X and
/// HDR10+ logos are licensed marks and an App Store build cannot carry them without an agreement
/// from their owners. Naming the format is what jellyfin-web, Plex and Infuse print as well.
///
/// A leaf that is handed its strings: the facts come from `MediaBadgeResolver`, the same resolver
/// the poster corners read, so a card and the page it opens can never disagree about a title.
struct FormatBadgeRow: View {
    let pills: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(pills, id: \.self) { pill in
                Text(pill)
                    .metadataBox()
            }
        }
        // Sodalite#171: set here and not inherited, because the episode panel and the phone-portrait
        // movie page place the row outside `ItemMetadataRow`.
        .foregroundStyle(.primary)
    }

    /// The row as a metadata-line segment, or no segment at all when there is nothing to say or the
    /// viewer turned the pills off. Empty rather than an empty view on purpose: the metadata line
    /// puts a separator in front of every segment it is given, and cannot see that one is blank.
    ///
    /// `sourceID` is the version the page is showing. Without it a multi-version title describes its
    /// first source while the viewer is looking at the one they picked, which is Sodalite#139 again,
    /// one row further up the page.
    static func extras(for item: JellyfinItem, sourceID: String?, enabled: Bool,
                       carriesHDR10Plus: Bool = false) -> [AnyView] {
        let pills = pills(for: item, sourceID: sourceID, enabled: enabled, carriesHDR10Plus: carriesHDR10Plus)
        guard !pills.isEmpty else { return [] }
        return [AnyView(FormatBadgeRow(pills: pills))]
    }

    /// What the row would say, for callers that place it themselves instead of handing it to the
    /// metadata row. Empty when the viewer turned the pills off or the server said nothing.
    ///
    /// `carriesHDR10Plus` is the probe's answer for this version (AE#579), and only a detail page
    /// has one: the poster corners read the same resolver without it, so a card says HDR10 where the
    /// page it opens says HDR10+. That is the one direction the disagreement is allowed to run, a
    /// grid cannot open every file it draws.
    static func pills(for item: JellyfinItem, sourceID: String?, enabled: Bool,
                      carriesHDR10Plus: Bool = false) -> [String] {
        guard enabled else { return [] }
        let badges = MediaBadgeResolver.badges(
            width: item.width,
            height: item.height,
            streams: item.effectiveMediaStreams(id: sourceID))
        return (carriesHDR10Plus ? badges.upgradedToHDR10Plus() : badges).detailPills
    }
}
