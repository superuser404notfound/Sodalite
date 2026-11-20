import SwiftUI

/// Who puts the fullscreen music player on screen, and whether it should be up at all.
///
/// Sodalite#140 follow-up. A view controller can present one thing at a time, and the shell is ONE
/// hosting controller: the album detail cover and the router's player cover are siblings in it, so
/// the second presentation is refused ("Attempt to present ... which is already presenting") and
/// only goes through once the album cover is dismissed. That is the bug as reported, "the player
/// only comes up after pressing back once".
///
/// It is NOT sidebar-only, which is what the first round of this believed. Re-measured in a
/// throwaway tvOS 26.5 harness (2026-09-14, Sodalite#110 round 3) against the real shape, TabView
/// with `Tab(value:)` over a NavigationStack whose content presents the cover: the router's cover is
/// refused there too. A `Tab`'s content does not get a presenting controller of its own. The report
/// that arrived from a top-bar build is the field half of the same measurement.
///
/// So the presenting side is chosen instead of assumed: a surface presented above the router claims
/// the player while it is on screen and hosts its own cover, the router keeps its own for everything
/// else. `ParentalGate.presenterStack` answers the same question for the PIN prompt.
@MainActor
@Observable
final class NowPlayingPresentation {

    /// Identity of one host, owned by that host's view for as long as it is on screen.
    struct HostToken: Hashable {
        private let id = UUID()
    }

    /// True while the player belongs on screen. WHICH view presents it is the hosts' business.
    private(set) var isPresented = false

    /// Hosts able to present, innermost last. Empty means the router's own cover.
    private(set) var hosts: [HostToken] = []

    /// The router presents when nothing above it has claimed the player.
    var routerPresents: Bool { hosts.isEmpty }

    func presents(_ token: HostToken) -> Bool { hosts.last == token }

    func present() { isPresented = true }

    func dismiss() { isPresented = false }

    func pushHost(_ token: HostToken) {
        // Order is what decides the presenter, so a host already in the list keeps its place: a
        // reappear (the cover above it closed) must not promote it past a host that is still up.
        guard !hosts.contains(token) else { return }
        hosts.append(token)
    }

    /// Called from the PRESENTING side's own state, never from the host's `onDisappear`: presenting
    /// the player takes its host off screen, so that callback fires for the very cover the host just
    /// put up and cannot tell it from the cover being closed. Releasing there would hand the
    /// presentation back to the router and dismiss the player in the update it appeared in, and
    /// guarding it against that leaves a claim behind whenever a cover really does go away while the
    /// player is up. Whoever owns the cover's item knows which of the two happened.
    func popHost(_ token: HostToken) {
        hosts.removeAll { $0 == token }
    }
}

// MARK: - Host

/// Presents the fullscreen player from this surface while it is on screen, and claims it from the
/// router for that long. Belongs on anything presented ABOVE the router that a track can be started
/// from, which today is the detail cover the album page lives in.
private struct NowPlayingCoverHost: ViewModifier {
    @Environment(\.dependencies) private var dependencies
    /// Owned by the presenting side, which is also where it is released.
    let token: NowPlayingPresentation.HostToken

    func body(content: Content) -> some View {
        let presentation = dependencies.musicPlaybackCoordinator.nowPlayingPresentation
        content
            .fullScreenCoverCompat(isPresented: Binding(
                get: { presentation.isPresented && presentation.presents(token) },
                set: { if !$0 { presentation.dismiss() } }
            )) {
                NowPlayingView(onClose: { presentation.dismiss() })
                    .pausesAppBackgroundMotion()
            }
            // On appear rather than in init: a host that never reached the screen cannot present,
            // and claiming from it would swallow the request the way the router's cover did.
            .onAppear { presentation.pushHost(token) }
    }
}

extension View {
    /// `token` belongs to the view that presents this surface, which releases the claim when it
    /// takes the surface away. See `NowPlayingPresentation.popHost`.
    func nowPlayingCoverHost(_ token: NowPlayingPresentation.HostToken) -> some View {
        modifier(NowPlayingCoverHost(token: token))
    }
}
