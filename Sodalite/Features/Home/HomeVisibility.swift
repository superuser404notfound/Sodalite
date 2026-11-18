import Foundation

/// The one definition of "Home is not the screen" (audit BRW-R205). HomeView's reload gates and
/// the banner's pause both read it. Home stays mounted under detail covers, the player and (tvOS)
/// every other tab page, and a reload landing next to a player opening its next stream is the
/// burst Sodalite#12 was about.
enum HomeVisibility {
    /// `playerPresented` is any player modal, including the ones AppRouter's deep-link cover opens
    /// (Top Shelf, Siri, `sodalite://play`), which Home's own `covered` and `heroPlayActive` never see
    /// (audit FR-BRW-1).
    static func isHidden(covered: Bool, heroPlayActive: Bool, pageShown: Bool, playerPresented: Bool = false) -> Bool {
        covered || heroPlayActive || !pageShown || playerPresented
    }
}
