import AetherEngine
import Foundation

struct LiveZapBanner: Equatable {
    let channel: JellyfinChannel?
    let direction: Int
}

extension PlayerViewModel {
    static let zapSettle: Duration = .milliseconds(600)

    var zapTarget: JellyfinChannel? {
        guard let current = liveChannel?.id else { return nil }
        return zapLineup?.neighbour(of: current, offset: zapPendingOffset)
    }

    func loadZapLineupIfNeeded() {
        guard isLiveSession, zapLineup == nil, zapLineupTask == nil,
              let service = liveTvService, let current = liveChannel?.id else { return }
        let filter = zapFilter
        let user = userID
        zapLineupTask = Task { [weak self] in
            var lineup = await Self.fetchLineup(service: service, userID: user, filter: filter)
            let all = GuideFilter(favoritesOnly: false, category: nil, kind: filter.kind)
            if let fetched = lineup, !fetched.contains(current), filter != all {
                lineup = await Self.fetchLineup(service: service, userID: user, filter: all)
            }
            guard let self else { return lineup }
            self.zapLineup = lineup
            self.zapLineupTask = nil
            LogTap.shared.note("[Zap] lineup=\(lineup?.channels.count.description ?? "failed") "
                + "filter=\(filter.favoritesOnly ? "fav" : "all")")
            self.refreshZapBanner()
            return lineup
        }
    }

    private static func fetchLineup(service: JellyfinLiveTvServiceProtocol, userID: String,
                                    filter: GuideFilter) async -> LiveChannelLineup? {
        var channels: [JellyfinChannel] = []
        while channels.count < GuideViewModel.channelHardCap {
            guard let page = try? await service.getChannels(
                userID: userID, startIndex: channels.count,
                limit: GuideViewModel.pageSize, filter: filter) else { return nil }
            channels += page.items
            if page.items.count < GuideViewModel.pageSize { break }
        }
        return LiveChannelLineup(channels: channels)
    }

    func requestZap(by delta: Int) {
        guard isLiveSession, !isTearingDown else { return }
        loadZapLineupIfNeeded()
        zapPendingOffset += delta
        refreshZapBanner(direction: delta)
        zapSettleTask?.cancel()
        zapSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.zapSettle)
            guard !Task.isCancelled else { return }
            await self?.commitZap()
        }
    }

    func refreshZapBanner(direction: Int? = nil) {
        guard zapPendingOffset != 0 || direction != nil else { return }
        let dir = direction ?? zapBanner?.direction ?? zapPendingOffset.signum()
        zapBanner = LiveZapBanner(channel: zapTarget, direction: dir)
    }

    /// Task 4 replaces this with the tune.
    func commitZap() async {}

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
