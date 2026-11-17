import Foundation

/// The one definition of "Home is not the screen" (audit BRW-R205). HomeView's reload gates and
/// the banner's pause both read it. Home stays mounted under detail covers, the player and (tvOS)
/// every other tab page, and a reload landing next to a player opening its next stream is the
/// burst Sodalite#12 was about.
enum HomeVisibility {
    static func isHidden(covered: Bool, heroPlayActive: Bool, pageShown: Bool) -> Bool {
        covered || heroPlayActive || !pageShown
    }
}
