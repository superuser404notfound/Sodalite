#if !os(macOS)
// Live playback presents the same UIKit modal as the rest; the Mac has no live player yet.
import SwiftUI
#if os(tvOS)
import AetherEngine
#endif
import UIKit

// MARK: - Live Player Launcher (UIKit modal presentation)

/// UIKit-modal launcher for the live player (mirrors PlayerLauncher with the
/// live initializer); presents when `isPresented` and `context` are set.
struct LivePlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let context: LivePlaybackContext?
    let playbackService: JellyfinPlaybackServiceProtocol
    let liveTvService: JellyfinLiveTvServiceProtocol
    let userID: String
    /// The server the channel lives on, not necessarily the active one (Sodalite#85).
    let serverName: String
    let preferences: PlaybackPreferences
    let directStreamMemory: LiveDirectStreamMemory
    /// The channel's server user's `EnableAudioPlaybackTranscoding` (#100).
    let canTranscodeAudio: Bool
    /// Same reason as PlayerLauncher: the theme has to be picked up on the SwiftUI side and carried
    /// across the UIKit boundary by hand.
    @Environment(\.appearanceTheme) private var appearanceTheme
    /// And the same for the server verdict (Sodalite#126).
    @Environment(\.appState) private var appState


    private var reachability: () -> ServerReachability {
        let state = appState
        return { state.serverReachability }
    }

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    /// The live view model's inputs, in one place shared with the grid's tile factory and the Mac launcher.
    private var sessionFactory: LiveSessionFactory {
        LiveSessionFactory(
            playbackService: playbackService, liveTvService: liveTvService, userID: userID,
            preferences: preferences, directStreamMemory: directStreamMemory,
            canTranscodeAudio: canTranscodeAudio, serverName: serverName, serverReachability: reachability)
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        #if os(tvOS)
        // Sodalite#175: the grid owns the session until it hands a player back or closes.
        if let multiview = host.multiview {
            if !isPresented { multiview.stopAll() }
            return
        }
        #endif
        if isPresented, let liveContext = self.context, host.presentedPlayer == nil, !host.isLaunching {
            // The same settled-chain present the VOD launcher uses (Sodalite#31): from the scene's top-most
            // controller, never from the host, which an iPhone channel list two sheets deep leaves blocked.
            host.isLaunching = true
            let isPresentedBinding = _isPresented
            let factory = sessionFactory
            let appearanceTheme = appearanceTheme
            host.presentWhenContextIsFree { [weak host] in
                let vm = factory.makeViewModel(
                    channel: liveContext.channel, program: liveContext.program, zapFilter: liveContext.zapFilter)
                let onDismiss: () -> Void = { [weak host] in
                    isPresentedBinding.wrappedValue = false
                    host?.tearDownPlayer {
                        #if os(tvOS)
                        host?.multiview = nil
                        #endif
                    }
                }
                let playerVC = PlayerHostController(viewModel: vm, theme: appearanceTheme, onDismiss: onDismiss)
                playerVC.modalPresentationStyle = .fullScreen
                #if os(tvOS)
                if let host {
                    LiveMultiviewCoordinator.wireEntry(
                        playerVC,
                        host: host,
                        fallbackChannel: liveContext.channel,
                        makeTileVM: tileFactory(factory: factory, zapFilter: liveContext.zapFilter),
                        theme: appearanceTheme,
                        onPlayerDismiss: onDismiss
                    )
                }
                #endif
                return playerVC
            }
        } else if !isPresented {
            // Programmatic dismissal (sign-out, deep link, teardown); else the live player stays as a
            // zombie modal.
            host.cancelPendingLaunch()
            if host.presentedPlayer != nil { host.tearDownPlayer(nil) }
        }
    }

    #if os(tvOS)
    /// Sodalite#175: a multiview tile is the same live player on its own engine.
    private func tileFactory(factory: LiveSessionFactory, zapFilter: GuideFilter) -> LiveMultiviewCoordinator.TileFactory {
        { channel, engine in
            factory.makeViewModel(
                channel: channel, program: channel.currentProgram, zapFilter: zapFilter,
                engine: engine, role: .secondary)
        }
    }
    #endif
}
#endif
