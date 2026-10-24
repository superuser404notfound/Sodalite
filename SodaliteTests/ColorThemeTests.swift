import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// `Color.Theme` is the app's neutral palette (Sodalite#106). Before it existed, the same scrim and
/// the same glass fill were re-typed in dozens of views and drifted apart, so what is pinned here is
/// both halves of the fix: the value each token carries, and the ORDER the fills and dims stand in.
/// The order is the part a retune can break silently, because a token that is edited on its own
/// still compiles and still looks deliberate; a resting ground that ends up brighter than the
/// focused one does not read as a bug until someone points a remote at it.
struct ColorThemeTests {

    // MARK: helpers

    private func components(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    /// Compares against a rebuilt literal rather than against raw numbers, so the assertion does not
    /// depend on which colour space `Color(white:)` resolves through. Editing a token still fails it.
    private func expectSame(_ token: Color, _ expected: Color, _ name: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let a = components(token), b = components(expected)
        #expect(abs(a.red - b.red) < 0.0001 && abs(a.green - b.green) < 0.0001
                && abs(a.blue - b.blue) < 0.0001 && abs(a.alpha - b.alpha) < 0.0001,
                "\(name) is no longer the value it was pinned at",
                sourceLocation: sourceLocation)
    }

    // MARK: values

    @Test("surfaces keep the greys the tiles were drawn against")
    func surfaces() {
        expectSame(Color.Theme.surface, Color(white: 0.1), "surface")
        expectSame(Color.Theme.surfaceElevated, Color(white: 0.15), "surfaceElevated")
    }

    @Test("row and chip fills keep their levels")
    func fills() {
        expectSame(Color.Theme.focusFill, Color.white.opacity(0.15), "focusFill")
        expectSame(Color.Theme.restFillStrong, Color.white.opacity(0.12), "restFillStrong")
        expectSame(Color.Theme.restFill, Color.white.opacity(0.08), "restFill")
        expectSame(Color.Theme.restFillFaint, Color.white.opacity(0.04), "restFillFaint")
    }

    @Test("the two edges and the two scrims keep their levels")
    func strokesAndScrims() {
        expectSame(Color.Theme.hairline, Color.white.opacity(0.18), "hairline")
        expectSame(Color.Theme.panelEdge, Color.white.opacity(0.12), "panelEdge")
        expectSame(Color.Theme.scrim, Color.black.opacity(0.55), "scrim")
        expectSame(Color.Theme.scrimHeavy, Color.black.opacity(0.85), "scrimHeavy")
    }

    @Test("the quiet label is opaque, at the level .secondary draws on the dark page")
    func quietLabel() {
        expectSame(Color.Theme.quietLabel, Color(white: 0.5), "quietLabel")
        #expect(components(Color.Theme.quietLabel).alpha == 1)
    }

    /// The content edge outlines a thumbnail or a swatch against a page it cannot predict; the panel
    /// edge outlines a surface whose own darkness already does most of that work. Rendered over
    /// eight cases, the content edge is the one that has to survive a dark subject on a dark page,
    /// so it stays the brighter of the two whatever either is retuned to.
    @Test("the content edge stays brighter than the panel edge")
    func edgeOrder() {
        #expect(components(Color.Theme.hairline).alpha > components(Color.Theme.panelEdge).alpha)
    }

    @Test("status tokens resolve to the system colours they stand for")
    func status() {
        expectSame(Color.Theme.success, .green, "success")
        expectSame(Color.Theme.destructive, .red, "destructive")
        expectSame(Color.Theme.recording, .red, "recording")
    }

    // MARK: invariants

    /// A control lights up on focus. Whatever the four levels are retuned to, the focused ground has
    /// to stay above the resting ones, and the faint ground has to stay the faintest.
    @Test("the focused ground is brighter than every resting ground")
    func fillOrder() {
        let focus = components(Color.Theme.focusFill).alpha
        let strong = components(Color.Theme.restFillStrong).alpha
        let rest = components(Color.Theme.restFill).alpha
        let faint = components(Color.Theme.restFillFaint).alpha
        #expect(focus > strong && strong > rest && rest > faint,
                "focus \(focus), restStrong \(strong), rest \(rest), faint \(faint)")
    }

    /// `restFillStrong` sits under a control whose focus state is the TINT, so it is allowed to be
    /// brighter than the other resting grounds. What it must not become is the focused white itself,
    /// which is the reading that would collapse the two families into one.
    @Test("the tint-focus resting ground stays below the white focus fill")
    func tintRestStaysBelowFocus() {
        #expect(components(Color.Theme.restFillStrong).alpha < components(Color.Theme.focusFill).alpha)
    }

    @Test("the heavy scrim is heavier than the standard one")
    func scrimOrder() {
        #expect(components(Color.Theme.scrimHeavy).alpha > components(Color.Theme.scrim).alpha)
    }

    // MARK: the level the two targets share

    /// The app draws the resume track in SwiftUI and the Top Shelf extension draws it in Core
    /// Graphics, on the same artwork, from what used to be a copy each. They now read one `Double`;
    /// this fails if a `Color` is ever hard-coded back over it.
    @Test("the resume track is the level the Top Shelf renderer draws")
    func resumeTrackIsShared() {
        expectSame(Color.Theme.resumeTrack, Color(white: NeutralLevel.resumeTrack), "resumeTrack")
        #expect(NeutralLevel.resumeTrack == 0.13)
    }

    /// Sodalite#104: one role on two grounds. The scrim variant is translucent because the player's
    /// scrim is already dark under it; the artwork variant is opaque because a bright still shows
    /// through. A third literal in a new meter is the drift this pair exists to stop.
    @Test("the two track grounds are one role, pinned together")
    func trackRolesArePinnedAsAPair() {
        expectSame(Color.Theme.trackOnScrim, Color.white.opacity(0.2), "trackOnScrim")
        #expect(components(Color.Theme.trackOnScrim).alpha < 1)
        #expect(components(Color.Theme.resumeTrack).alpha == 1)
    }

    /// Opaque and neutral, which is the whole reason it is not `surface` or a translucent white: it
    /// sits on artwork and has to hold its contrast against a bright still.
    @Test("the resume track is an opaque neutral grey, not a wash over the artwork")
    func resumeTrackIsOpaqueGrey() {
        let track = components(Color.Theme.resumeTrack)
        #expect(track.alpha == 1)
        #expect(abs(track.red - track.green) < 0.0001 && abs(track.green - track.blue) < 0.0001)
        #expect(components(Color.Theme.surface).red != track.red,
                "the track is tuned against artwork, the surface against the page; keep them apart")
    }
}
