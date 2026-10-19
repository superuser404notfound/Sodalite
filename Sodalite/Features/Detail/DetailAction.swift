import Foundation

/// Which control in a detail page's action row holds focus, or nil for "focus is somewhere else on
/// the page" (Sodalite#146).
///
/// The page needs that second answer, and a Bool per button cannot give it: two `.focused($flag)`
/// bindings racing on a move between neighbours can both settle false. One value for the whole row
/// can only ever name one control, which is also what the focus engine guarantees.
///
/// What it is for: tvOS resolves an up-move geometrically from the centre of the focused element
/// and keeps no memory of where focus came from, so a card below the fold lands on whichever button
/// happens to sit above it, which for a card past the row's width is the last one, Delete
/// (Sodalite#53, measured). The only thing that changes the landing is taking the other candidates
/// out of the engine with `.disabled` while focus is not in the row, and this is how the page knows.
enum DetailAction: Hashable {
    case play
    case version
    case shuffle
    case replay
    case trailer
    case favorite
    case watched
    case rating
    case spoiler
    case goToShow
    case request
    case moreDetails
    case delete
}
