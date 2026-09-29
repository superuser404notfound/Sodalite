import AetherEngine
import Foundation

extension PlayerViewModel {
    /// Single owner of channel-bound state for a zap (Sodalite#173), the live counterpart of
    /// `resetSessionState`. The audio pick goes too: a recovery retune keeps it on purpose, but stream
    /// indices only mean something on the channel they were picked on.
    func resetLiveSessionState(switchingTo channel: JellyfinChannel) {
        liveChannel = channel
        liveProgram = channel.currentProgram
        item = JellyfinItem(liveChannel: channel, program: channel.currentProgram)
        liveProgramFollow?.cancel()
        liveProgramFollow = nil
        liveProgramWindow = []
        liveSeekableRange = nil
        isAtLiveEdge = true
        behindLiveSeconds = 0
        liveRetuneInFlight = false
        lastLiveRetuneAt = nil
        liveRetuneCount = 0
        liveFirstPlayingAt = nil
        hasStartedPlaying = false
        liveTunerReleasedWhileSuspended = false
        pendingLiveAudioStreamIndex = nil
        errorMessage = nil
        videoFormat = .sdr
        clearVideoFormatAnnouncement()
        subtitleCues = []
        subtitleStreams = []
        externalEngineTrackIDs = [:]
        activeSubtitleIndex = nil
        activeAudioIndex = nil
        forcedSubtitleFallback = .none
        activeSubtitleCodec = nil
        deactivateASSRendering()
        showControls = false
        isScrubbing = false
        controlsFocus = .progressBar
        trackDropdown = .none
        NotificationCenter.default.post(
            name: .playerDidSwitchItem, object: nil,
            userInfo: [PlayerItemSwitchKey.item: item])
    }
}
