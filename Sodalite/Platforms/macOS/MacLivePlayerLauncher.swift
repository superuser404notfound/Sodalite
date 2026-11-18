import SwiftUI

/// The Mac's `LivePlayerLauncher`: the live twin of `PlayerLauncher` here, exactly as it is on the
/// other platforms, so `LiveTVTabView` mounts the same overlay whichever one it is built for.
struct LivePlayerLauncher: View {
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

    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.appState) private var appState

    @State private var session: PlayerViewModel?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .modifier(MacPlayerSessionPresenter(
                isPresented: $isPresented, session: $session, theme: appearanceTheme,
                launchKey: context?.id,
                makeViewModel: { context.map(makeViewModel(for:)) }))
    }

    private func makeViewModel(for context: LivePlaybackContext) -> PlayerViewModel {
        let state = appState
        return LiveSessionFactory(
            playbackService: playbackService, liveTvService: liveTvService, userID: userID,
            preferences: preferences, directStreamMemory: directStreamMemory,
            canTranscodeAudio: canTranscodeAudio, serverName: serverName,
            serverReachability: { state.serverReachability }
        ).makeViewModel(channel: context.channel, program: context.program, zapFilter: context.zapFilter)
    }
}
