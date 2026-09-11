import SwiftUI

/// The motion half of the focus gesture: how far a control lifts, how it settles, and whether it
/// casts a shadow while it is up. `MediaFocusRing` centralizes the ring half; this is its twin, and
/// the two are wired together below so they can never again disagree.
///
/// A token is named for the ROLE a control plays, not for its value, the way `Color.Theme` names the
/// palette. That matters more here than it looks, because a scale factor is not comparable across
/// roles: the same 1.05 moves a 180pt profile card by 4.5pt per side and a 360pt episode still by
/// 9pt. Read as bare numbers the app looked like it carried nine arbitrary lifts; read as
/// displacement it carries one gesture applied to elements that differ in width by a factor of five
/// (Sodalite#130). So a role's scale is only ever compared against other sites of the SAME role.
///
/// The shadow is part of a role only where every site of that role already drew the same one. A
/// shadow is tuned against the ground it falls on, which is why `Color+Theme.swift` keeps
/// `.shadow(color:)` literal, and a role cannot know whether its call site sits on the page, on
/// `.ultraThinMaterial`, over video, or inside a column that clips. Those take ``flat`` when they
/// draw none, or ``withShadow(opacity:radius:y:)`` when they draw their own, with the reason at the
/// call site. Three controls sit outside the roles entirely and say so where they are written: the
/// Now Playing primary, the album cover's resting shadow, and the licence reading block.
struct FocusResponse: Equatable {

    struct Shadow: Equatable {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    let scale: CGFloat
    let shadow: Shadow?
    let animation: Animation

    /// The same response with no shadow at all, for a site that never drew one.
    var flat: FocusResponse {
        FocusResponse(scale: scale, shadow: nil, animation: animation)
    }

    /// The same response carrying a shadow of its own. The deviation belongs in the token rather
    /// than in a `.shadow` after the modifier: the settle is applied last, so a shadow appended
    /// behind it would be the one part of the gesture that snaps.
    func withShadow(opacity: Double, radius: CGFloat, y: CGFloat) -> FocusResponse {
        FocusResponse(scale: scale, shadow: Shadow(opacity: opacity, radius: radius, y: y), animation: animation)
    }
}

extension FocusResponse {

    /// One settle time for the whole app. Of the 44 lifts that had one it was 0.15 at 28 and 0.2 at
    /// 11, with a lone 0.12 and two controls that had no animation at all, so identical controls
    /// settled at different speeds: the profile picker at 0.15 handed straight over to a library
    /// grid at 0.2, wearing the same lift and the same shadow. A duration, unlike a scale, IS
    /// comparable across roles, which is why this one is shared and the scales are not.
    static let settle = Animation.easeInOut(duration: 0.15)

    /// Artwork that lifts off the page: grid poster, profile card, episode still, cast portrait,
    /// recording thumbnail.
    static let card = FocusResponse(
        scale: 1.05,
        shadow: Shadow(opacity: 0.4, radius: 20, y: 10),
        animation: settle
    )

    /// A settings tile and everything shaped like one. The scale and shadow are
    /// `SettingsTileButtonStyle`'s, which 68 call sites already wear.
    static let tile = FocusResponse(
        scale: 1.03,
        shadow: Shadow(opacity: 0.3, radius: 15, y: 8),
        animation: settle
    )

    /// A row that stands as its own panel in a list: a value picker, a server, a track.
    static let row = FocusResponse(
        scale: 1.015,
        shadow: Shadow(opacity: 0.3, radius: 14, y: 6),
        animation: settle
    )

    /// A row inside a larger box, which has no ground of its own to lift off.
    static let inline = FocusResponse(scale: 1.02, shadow: nil, animation: settle)

    /// A small tappable control: filter chip, season tab, PIN key, the circular search clear.
    static let chip = FocusResponse(scale: 1.05, shadow: nil, animation: settle)

    /// The player's transport pills. `.smooth` is not drift: the enclosing row forces the curve
    /// through a transaction so the siblings interpolate together.
    static let pill = FocusResponse(
        scale: 1.08,
        shadow: Shadow(opacity: 0.3, radius: 10, y: 5),
        animation: .smooth(duration: 0.32)
    )

    /// The same response, but never growing the control by more than `maxPerSide` points on a side.
    ///
    /// The file's thesis, applied inside a single role: a scale is one gesture only among controls
    /// of one width, because it grows a control by half its growth on each edge. That holds across
    /// roles, and it holds within a role as soon as one of its sites is free to be any width. The
    /// action row's version button carries a label the SERVER writes, and at 1.08 a 723 pt pill grew
    /// 29 pt per side into a row that sets its siblings 16 pt apart, so focus put it over both
    /// neighbours (Sodalite#139). Capped, the wide control lifts the same DISTANCE as the narrow
    /// one instead of the same percentage, which is the comparison this file says to make.
    ///
    /// A width of zero (before the control has measured itself) keeps the role's own scale.
    func capped(toLift maxPerSide: CGFloat, width: CGFloat) -> FocusResponse {
        guard width > 0 else { return self }
        return FocusResponse(
            scale: min(scale, 1 + (2 * maxPerSide) / width),
            shadow: shadow,
            animation: animation
        )
    }
}

extension View {

    /// Applies the lift, the shadow and the settle of a focus role in one place, so a control cannot
    /// pick up one half of the gesture and hand-roll the other.
    ///
    /// The shadow is applied unconditionally, at zero opacity where the role carries none. Every
    /// site in the app already draws a zero-opacity shadow in its resting state, so this is inert,
    /// and it keeps one code path instead of a `_ConditionalContent` whose branch would depend on a
    /// token rather than on state.
    /// `pressedScale` is a second gesture and not part of the role: a click shrinks a control that
    /// focus may already have raised. Focus wins where both are true, which is what the call sites
    /// wrote by hand. Passing it here rather than stacking a second `scaleEffect` keeps that, since
    /// two scale modifiers would multiply into a shrunken focused control mid-click.
    func focusResponse(_ response: FocusResponse, isFocused: Bool,
                       isPressed: Bool = false, pressedScale: CGFloat = 1.0) -> some View {
        scaleEffect(isFocused ? response.scale : (isPressed ? pressedScale : 1.0))
            .shadow(
                color: .black.opacity(isFocused ? (response.shadow?.opacity ?? 0) : 0),
                radius: response.shadow?.radius ?? 0,
                y: response.shadow?.y ?? 0
            )
            .animation(response.animation, value: isFocused)
    }
}
