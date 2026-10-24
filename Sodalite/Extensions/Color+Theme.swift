import SwiftUI

/// The app's neutral palette. Chromatic colour is the accent system's job (`AppearanceTheme.swift`);
/// everything here is a grey, a dim or a system status colour, and none of it follows the tint.
///
/// A token is named for the ROLE it plays, not for its value, because several roles share a number
/// today and would not survive a retune together. In particular these tokens are for FLAT SURFACES
/// only. A `.shadow(color:)` is not a scrim and a gradient stop is not a fill: both are tuned
/// against what they sit on (subtitle text over video, the hero mark over artwork, the resume label
/// over a bright still) and several carry a measurement in a comment at the call site. Folding those
/// into a shared token would let one retune quietly undo the measurement (Sodalite#106).
extension Color {
    enum Theme {
        // MARK: Surfaces

        /// Neutral card / tile / poster-placeholder ground.
        static let surface = Color(white: 0.1)
        /// Raised neutral surface (focused guide cells, elevated sheets).
        static let surfaceElevated = Color(white: 0.15)
        /// Resume-progress track ON ARTWORK, shared with the Top Shelf renderer. Opaque, and that is
        /// the whole difference from ``trackOnScrim``: over a bright still a translucent track washes
        /// out. See ``NeutralLevel/resumeTrack``.
        static let resumeTrack = Color(white: NeutralLevel.resumeTrack)
        /// Unplayed track of a transport meter, which always sits on the player's own scrim. Sodalite#104
        /// named this against ``resumeTrack``: the two are one role on two grounds, and a third literal
        /// in a new meter is the drift the pair exists to stop.
        static let trackOnScrim = Color.white.opacity(0.2)

        // MARK: Row and chip fills
        //
        // Two families, distinguished by what the focused state does. Where FOCUS goes white, the
        // resting ground is dark (`restFill` / `restFillFaint`) and focus lifts it to `focusFill`.
        // Where focus goes to the tint, the resting ground is brighter (`restFillStrong`), because
        // the lift comes from the colour rather than from the level. Reading `restFillStrong` as a
        // drifted `focusFill` is the mistake to avoid, they belong to different controls.

        /// Focused ground of a control. One value app-wide: six rows were written at 0.12 and read
        /// as a quieter focus than every neighbour, which is the drift this token exists to end.
        /// Also the ground of a highlight that only LOOKS focused, like the stats overlay's cursor,
        /// which the focus engine never reaches (AVKit eats the arrow presses) and which would
        /// otherwise sit below the rest of the app.
        static let focusFill = Color.white.opacity(0.15)
        /// Resting ground of a control whose focus state is the tint. This is the only thing white
        /// at 0.12 means as a FILL, so a new one at that level is either this or a mistake.
        /// ``panelEdge`` shares the number and is a stroke; they are tuned separately on purpose.
        static let restFillStrong = Color.white.opacity(0.12)
        /// Resting or selected ground of a control whose focus state is white; also the static
        /// ground of a chip or panel that does not take focus at all.
        static let restFill = Color.white.opacity(0.08)
        /// Faintest resting ground, for a row nested inside an already lifted surface.
        static let restFillFaint = Color.white.opacity(0.04)

        // MARK: Strokes
        //
        // Two edges, because a 1pt white hairline does two different jobs and only one of them can
        // see the value it is given. Rendered over eight cases (`ImageRenderer` sheet, 2026-09-04):
        // against bright content the stroke is invisible at every level between 0.08 and 0.18, so
        // brightness there is free; against a panel it is visible throughout, so that is where the
        // level is actually a decision.

        /// Edge around CONTENT the app cannot predict: a scrub thumbnail, an accent swatch, an
        /// avatar, a badge on artwork. Bright, because its failure case is a dark subject on a dark
        /// page, where this stroke is the only thing separating the two, and because the bright case
        /// that would punish a bright stroke swallows it at any level anyway.
        static let hairline = Color.white.opacity(0.18)

        /// Edge around a KNOWN dark or frosted panel. Quieter than `hairline`, but not as quiet as
        /// the 0.08 three of these used to carry: a material lightens what is behind it, which
        /// compresses a white stroke, and over video 0.08 came to a luminance step of 0.033 against
        /// its own fill, which is nothing. This lands at 0.049 there and reads as an edge without
        /// outlining the card.
        static let panelEdge = Color.white.opacity(0.12)

        // MARK: Text

        /// Quiet text over content that can move behind it, at the level `.secondary` draws on the
        /// app's dark page. tvOS renders `.secondary` with a plus-lighter blend, so it takes on
        /// whatever passes under it (vanishing over white, flickering under a scrolling grid's focus
        /// shadows) and only Reduce Transparency stops that (Sodalite#206). Opaque on purpose.
        static let quietLabel = Color(white: 0.5)

        // MARK: Scrims
        //
        // Flat, full-surface dims only. Not shadows, not gradient stops.

        /// Panel and content-block scrim under body copy.
        static let scrim = Color.black.opacity(0.55)
        /// Heavy dim behind a sheet or an expanded panel. The parental-control covers sit deliberately
        /// higher (0.92 / 0.95) and keep their own literal.
        static let scrimHeavy = Color.black.opacity(0.85)

        // MARK: Status
        //
        // Error TEXT keeps plain `.red`: that is SwiftUI's own semantic for it and a token adds a
        // name without adding a decision. The two domain status switches (`SeerrMediaStatus.color`,
        // `SupportDevelopmentView`'s banner tint) are already single-definition palettes and stay
        // whole; pulling one case out of a six-case switch would scatter it, not centralise it.

        /// Available, verified, finished.
        static let success = Color.green
        /// The fill of a destructive action, and the trash glyph that opens one.
        static let destructive = Color.red
        /// Recording in progress, and the timer dot that promises one.
        static let recording = Color.red
    }
}
