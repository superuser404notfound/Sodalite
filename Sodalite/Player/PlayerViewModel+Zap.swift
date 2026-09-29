import AetherEngine
import Foundation

struct LiveZapBanner: Equatable {
    let channel: JellyfinChannel?
    let direction: Int
}

extension PlayerViewModel {
    static let zapSettle: Duration = .milliseconds(600)

    var zapTarget: JellyfinChannel? {
        neighbourChannel(offset: zapPendingOffset)
    }

    private func neighbourChannel(offset: Int) -> JellyfinChannel? {
        guard let current = liveChannel?.id else { return nil }
        return zapLineup?.neighbour(of: current, offset: offset)
    }

    func loadZapLineupIfNeeded() {
        guard isLiveSession, !isTearingDown, zapLineup == nil, zapLineupTask == nil,
              let service = liveTvService, let current = liveChannel?.id else { return }
        let filter = zapFilter
        let user = userID
        zapLineupTask = Task { [weak self] in
            let all = GuideFilter(favoritesOnly: false, category: nil, kind: filter.kind)
            var used = filter
            var result = await Self.fetchLineup(service: service, userID: user, filter: filter)
            if case .success(let fetched) = result, !fetched.contains(current), filter != all {
                used = all
                result = await Self.fetchLineup(service: service, userID: user, filter: all)
            }
            let lineup = try? result.get()
            guard !Task.isCancelled, let self else { return lineup }
            self.zapLineup = lineup
            self.zapLineupTask = nil
            let scope = used.favoritesOnly ? "fav" : "all"
            switch result {
            case .success(let fetched):
                LogTap.shared.note("[Zap] lineup=\(fetched.channels.count) filter=\(scope)")
            case .failure(let error):
                LogTap.shared.note("[Zap] lineup failed filter=\(scope) error=\(error)")
            }
            self.refreshZapBanner()
            return lineup
        }
    }

    private static func fetchLineup(service: JellyfinLiveTvServiceProtocol, userID: String,
                                    filter: GuideFilter) async -> Result<LiveChannelLineup, Error> {
        var channels: [JellyfinChannel] = []
        while channels.count < GuideViewModel.channelHardCap {
            do {
                let page = try await service.getChannels(
                    userID: userID, startIndex: channels.count,
                    limit: GuideViewModel.pageSize, filter: filter)
                channels += page.items
                if page.items.count < GuideViewModel.pageSize { break }
            } catch {
                return .failure(error)
            }
        }
        return .success(LiveChannelLineup(channels: channels))
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

    /// Turns the settled presses into a retune. Commits run one after another and after any retune in
    /// flight, so a newer press never closes a tuner something else is still closing; it cancels the
    /// previous commit's tune instead.
    func commitZap() async {
        // A press made before the lineup arrived resolves against it once it lands; a newer press
        // that cancelled this settle commits the sum itself.
        if zapLineup == nil {
            loadZapLineupIfNeeded()
            if let load = zapLineupTask { _ = await load.value }
            guard !Task.isCancelled else { return }
        }
        let offset = zapPendingOffset
        zapPendingOffset = 0
        guard neighbourChannel(offset: offset) != nil else {
            zapBanner = nil
            return
        }
        zapCommitGeneration += 1
        let generation = zapCommitGeneration
        zapBannerHideTask?.cancel()
        loadTask?.cancel()
        liveRetuneTask?.cancel()
        let prior = zapCommitTask
        let retune = liveRetuneTask
        let commit = Task { [weak self] in
            await prior?.value
            await retune?.value
            await self?.performZap(offset: offset, generation: generation)
        }
        zapCommitTask = commit
        await commit.value
    }

    private func performZap(offset: Int, generation: Int) async {
        let previous = loadTask
        previous?.cancel()
        await previous?.value
        guard !isTearingDown, let from = liveChannel, let target = neighbourChannel(offset: offset) else { return }
        LogTap.shared.note("[Zap] from=\(from.id) to=\(target.id) offset=\(offset) "
            + "lineup=\(zapLineup?.channels.count ?? 0) filter=\(zapFilter.favoritesOnly ? "fav" : "all")")
        // The old channel's engine sinks would read its dying pipeline as an error or a source reset;
        // the close stops its progress timer first thing.
        cancellables.removeAll()
        await closeLiveSessionServerSide()
        guard !isTearingDown else { return }
        resetLiveSessionState(switchingTo: target)
        // A newer commit is queued: it tunes from this channel, so opening one here would only be released again.
        guard generation == zapCommitGeneration else { return }
        if zapPendingOffset != 0 {
            refreshZapBanner()
        } else {
            zapBanner = LiveZapBanner(channel: target, direction: offset.signum())
        }
        let start = zapStartPlayback
        let task = Task<Void, Never> { [weak self] in
            guard !Task.isCancelled else { return }
            if let start { await start() } else { await self?.startPlayback() }
        }
        loadTask = task
        await task.value
        guard generation == zapCommitGeneration else { return }
        armZapBannerHide()
    }

    private func armZapBannerHide() {
        zapBannerHideTask?.cancel()
        zapBannerHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.zapPendingOffset == 0 else { return }
            self.zapBanner = nil
        }
    }

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
