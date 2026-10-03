import SwiftUI

/// When the resume indicator is drawn at all. One rule for both cards, like `TopShelfProgress` is
/// for the shelf, because the two used to hold their own copies of it and only one of them read the
/// live watched state.
enum ResumeIndicator {
    /// nil means "draw nothing". Two cases earn that.
    ///
    /// A finished item, the case that changed in Sodalite#99: the gate used to be
    /// `playedPercentage > 0` alone, so an item watched to the end wore a full bar under the watched
    /// check, one state drawn twice. What excludes it is the POSITION, not the watched flag: past
    /// the resume threshold Jellyfin's `UpdatePlayState` and ``JellyfinItem/setResumePosition`` both
    /// write "watched" and position 0 together.
    ///
    /// The watched flag is deliberately not read here, and that is the fix for a report from
    /// 2026-09-10. It says the viewer finished this once, which is no answer to whether they are
    /// partway through it NOW: on a stop between `MinResumePct` and `MaxResumePct` the server writes
    /// the new position and never touches `Played` (same branch in 10.9, 10.10 and master), so
    /// "seen, and three minutes in again" is a state it hands out on its own, and for a re-watched
    /// children's series it is the normal one. Reading the flag hid the capsule on exactly those
    /// episodes while the Top Shelf cell beside them drew it, `TopShelfProgress` never having
    /// carried the gate.
    ///
    /// A CONTAINER, the case that changed in Sodalite#135. The bar says "you are partway through
    /// this one thing", and a series, box set, album or playlist has no such point: its
    /// `playedPercentage` counts CHILDREN watched. Reading it as progress put a capsule under every
    /// favourited series for the share of its episodes seen, which looks like a resume point and is
    /// not one. `playbackPositionTicks` is what separates the two, and it is the same gate
    /// ``JellyfinItem/resumeRemainingTicks`` already applies to the label beside the bar. That the
    /// label was honest while the bar was not is why this survived: a series simply drew the capsule
    /// alone, which reads as deliberate.
    static func fraction(playedPercentage: Double?, playbackPositionTicks: Int64?) -> Double? {
        guard let playbackPositionTicks, playbackPositionTicks > 0,
              let playedPercentage, playedPercentage > 0
        else { return nil }
        return min(playedPercentage / 100, 1)
    }

    /// How far through an item a viewer is, counting a container's children. This is the pre-#135
    /// rule, kept because it is the honest answer to a different question: "how much of this series
    /// have I seen" has no resume point behind it and is still a real number.
    ///
    /// The watched flag still has a job in THIS one, where the resume rule above drops it: a
    /// CONTAINER that is watched is at 100 percent by definition, so the flag and the percentage are
    /// one sentence and the check already says it. A watched LEAF with a position is the other case,
    /// a re-watch, and then the position is the share: the same movie must not read 49 percent on
    /// the episode-shaped card and blank on its poster.
    static func watchedShare(playedPercentage: Double?, isPlayed: Bool,
                             playbackPositionTicks: Int64?) -> Double? {
        guard let playedPercentage, playedPercentage > 0 else { return nil }
        guard !isPlayed || (playbackPositionTicks ?? 0) > 0 else { return nil }
        return min(playedPercentage / 100, 1)
    }

    /// The whole card rule in one place, so it can be read and tested without a view.
    ///
    /// The episode card asks for a resume POINT: it shows the thing being watched, and a capsule
    /// there means "you stopped here". The poster asks a different question, and only when the
    /// viewer opted in (Sodalite#136): "how far through this am I", which for a series is the share
    /// of its episodes seen and has no playback position behind it. Requiring one there left the
    /// switch inert on exactly the rows it was asked for, since a Favourites row is series. The
    /// album card answers neither question, having no per-item progress of its own at all.
    static func cardFraction(style: MediaCardStyle,
                             posterProgressEnabled: Bool,
                             playedPercentage: Double?,
                             isPlayed: Bool,
                             playbackPositionTicks: Int64?) -> Double? {
        switch style {
        case .square:
            return nil
        case .landscape:
            return fraction(playedPercentage: playedPercentage,
                            playbackPositionTicks: playbackPositionTicks)
        case .poster:
            guard posterProgressEnabled else { return nil }
            return watchedShare(playedPercentage: playedPercentage, isPlayed: isPlayed,
                                playbackPositionTicks: playbackPositionTicks)
        }
    }
}

/// Resume indicator on card artwork: an inset capsule with the remaining time beside it, in one row
/// along the bottom of the image. `MediaCard` and the episode strip share it.
///
/// It replaces a 10pt band that ran edge to edge inside the card's own 12pt clip (Sodalite#99).
/// That band was a fixed height on every tier, so it measured 4.5 percent of a TV poster and 8.3
/// percent of a phone one, it ignored the card-scale setting, and, having no gap to the card edge,
/// it read as a heavy bottom frame rather than as progress. Everything here is a fraction of the
/// tier's poster width times that setting, the convention `PosterBadgeMetrics` already sets, so a
/// landscape card wears the same indicator as the poster beside it and both track the setting.
///
/// No scrim under the row, unlike the Top Shelf artwork, which needs one because the system draws
/// its own title into the same corner. The scrim variant only dimmed the lower third of every
/// partly-watched card in a row where nearly all of them are, so each mark brings its own ground
/// instead: the track is opaque, and the remaining time sits on a badge filled with the accent.
///
/// That badge replaces a bare white number on a two-layer shadow (Sodalite#176). A shadow darkens
/// what is behind a glyph by a share, so on a white still the number stood on light grey, and on a
/// busy one the edge it drew was one more edge among the picture's own.
struct ResumeProgressBar: View {
    /// 0...1. Callers hold Jellyfin percentages; they convert, so the view has a single unit.
    let fraction: Double

    /// Remaining time, already formatted and localized. `nil` draws the capsule alone, which is what
    /// a container item gets: a series or an album has a percentage but no resume point, so there is
    /// no honest number to put beside it.
    var remaining: String?

    /// The tier's poster width, not this card's width.
    let posterWidth: CGFloat
    var scale: CGFloat = 1

    /// The badge needs the accent's ROLES, fill and what is legible on it, which the environment
    /// `.tint` cannot hand out: it is an opaque ShapeStyle.
    @Environment(\.appearanceTheme) private var appearanceTheme

    private var inset: CGFloat { PosterBadgeMetrics.checkInset(posterWidth: posterWidth, scale: scale) }
    private var trackHeight: CGFloat { PosterBadgeMetrics.trackHeight(posterWidth: posterWidth, scale: scale) }
    private var gap: CGFloat { PosterBadgeMetrics.labelGap(posterWidth: posterWidth, scale: scale) }
    private var labelSize: CGFloat { PosterBadgeMetrics.remainingLabelSize(posterWidth: posterWidth, scale: scale) }

    var body: some View {
        row
            // The same inset as the watched badge opposite, so the two overlays line up on the
            // card's margin instead of each keeping their own.
            .padding(inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// `ViewThatFits` is the guard rule: it measures the label at its natural width against a track
    /// held to its minimum share of the card, and falls back to the track alone when the two cannot
    /// both have their space. Estimating the text width instead would need a font metric per locale
    /// and would guess wrong in exactly the languages that need the rule.
    @ViewBuilder
    private var row: some View {
        if let remaining {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: gap) {
                    track.frame(minWidth: posterWidth * PosterBadgeMetrics.minimumTrackShare * scale)
                    label(remaining)
                }
                unlabelledTrack
            }
        } else {
            unlabelledTrack
        }
    }

    /// The capsule alone, in the height a labelled row would have. Without this the row is only as
    /// tall as the capsule when there is no time to show, so its meter sits lower on the card than
    /// the meter on the card beside it, which is visible in any row that mixes the two.
    ///
    /// The spacer is the badge's own text and padding, hidden, rather than an arithmetic line
    /// height: a font's line height is not its point size, and guessing the factor would drift per
    /// platform.
    private var unlabelledTrack: some View {
        ZStack {
            badgeText("0").hidden()
            track
        }
    }

    private var track: some View {
        Capsule()
            .fill(Color.Theme.resumeTrack)
            .frame(height: trackHeight)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        // .tint reads the WindowGroup tint and follows supporter state. Never
                        // Color.accentColor, which is the static asset (hard-coded blue).
                        .fill(.tint)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            // Flattened for the same reason as the badge, or the fill casts a shadow into the track.
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: trackHeight * 0.5)
    }

    private func label(_ text: String) -> some View {
        badgeText(text)
            .foregroundStyle(appearanceTheme.palette.foreground.color)
            .background(appearanceTheme.palette.control.color, in: Capsule())
            // The same edge the track wears, for the badge itself, when the accent and the still
            // share a colour. Flattened first: a shadow on an uncomposited view is applied to each
            // child, so the number cast its own shadow onto the badge (seen on the TV, 2026-10-03).
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: trackHeight * 0.5)
    }

    /// The number in the badge's geometry, without its colours, so the unlabelled row can reserve
    /// exactly this height.
    private func badgeText(_ text: String) -> some View {
        Text(text)
            // Fixed, like the poster badges: it is sized off the artwork it sits on, so growing it
            // with the viewer's Dynamic Type setting would push it out of a card that stayed put.
            .font(.system(size: labelSize, weight: .semibold))
            .lineLimit(1)
            // Never truncate. The row either has room for the whole badge or drops it, and that is
            // ViewThatFits' decision, which needs the natural width to make.
            .fixedSize()
            .padding(.horizontal, labelSize * PosterBadgeMetrics.pillHorizontalPadding)
            .padding(.vertical, labelSize * PosterBadgeMetrics.pillVerticalPadding)
    }
}
