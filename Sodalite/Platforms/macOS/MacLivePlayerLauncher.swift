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
            .modifier(MacPlayerWindowPresenter(session: $session, theme: appearanceTheme) {
                isPresented = false
            })
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented, session == nil, let context {
                    session = makeViewModel(for: context)
                } else if !presented {
                    session = nil
                }
            }
            .onChange(of: appState.requestPlayerDismissal) { _, _ in
                isPresented = false
            }
    }

    private func makeViewModel(for context: LivePlaybackContext) -> PlayerViewModel {
        let state = appState
        return PlayerViewModel(
            item: JellyfinItem(liveChannel: context.channel, program: context.program),
            startFromBeginning: true,
            playbackService: playbackService,
            userID: userID,
            preferences: preferences,
            canTranscodeAudio: canTranscodeAudio,
            isLiveSession: true,
            liveChannel: context.channel,
            liveProgram: context.program,
            liveTvService: liveTvService,
            directStreamMemory: directStreamMemory,
            zapFilter: context.zapFilter,
            serverName: serverName,
            serverReachability: { state.serverReachability }
        )
    }
}
