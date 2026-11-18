import AetherEngine
import Foundation

/// Everything a live `PlayerViewModel` is built from besides the channel. The live launcher, the
/// multiview tile factory and the Mac launcher all hold one, so a new live dependency (the way
/// `canTranscodeAudio` and `serverReachability` arrived) is added here and in no other place
/// (audit PHOST-R204).
struct LiveSessionFactory {
    let playbackService: JellyfinPlaybackServiceProtocol
    let liveTvService: JellyfinLiveTvServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    let directStreamMemory: LiveDirectStreamMemory
    /// The channel's server user's `EnableAudioPlaybackTranscoding` (#100).
    let canTranscodeAudio: Bool
    /// The server the channel lives on, not necessarily the active one (Sodalite#85).
    let serverName: String
    let serverReachability: () -> ServerReachability

    /// `engine` and `role` are for a multiview tile, which plays on an engine of its own.
    @MainActor
    func makeViewModel(
        channel: JellyfinChannel,
        program: JellyfinProgram?,
        zapFilter: GuideFilter,
        engine: AetherEngine? = nil,
        role: SharedOutputRole = .primary
    ) -> PlayerViewModel {
        PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: program),
            startFromBeginning: true,
            playbackService: playbackService,
            userID: userID,
            preferences: preferences,
            canTranscodeAudio: canTranscodeAudio,
            isLiveSession: true,
            liveChannel: channel,
            liveProgram: program,
            liveTvService: liveTvService,
            directStreamMemory: directStreamMemory,
            zapFilter: zapFilter,
            serverName: serverName,
            serverReachability: serverReachability,
            engine: engine,
            sharedOutputRole: role
        )
    }
}
