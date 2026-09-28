import Foundation
import AetherEngine

extension PlayerViewModel {

    /// Resolves the successor once per session, right after the first frame.
    ///
    /// Deliberately not gated on the end window any more: fast-forwarding or scrubbing to 100% skips
    /// that window entirely, so `nextEpisode` stayed nil and end-of-media routed like end-of-content,
    /// closing the player instead of advancing (Sodalite#67). One small item query per episode buys a
    /// successor that is ready however the playhead reaches the end.
    func resolveNextEpisode() {
        guard !hasFetchedNextEpisode else { return }

        // Shuffle/play queue: next item is the next queue entry, resolved synchronously. Must run before the seriesId guard (queue items are often movies, no seriesId). Queue exhausted -> nextEpisode stays nil and the engine's .idle handler dismisses.
        if isQueuePlayback {
            hasFetchedNextEpisode = true
            let nextIdx = queueIndex + 1
            if playQueue.indices.contains(nextIdx) {
                nextEpisode = playQueue[nextIdx]
            }
            return
        }

        guard item.seriesId != nil else { return }

        hasFetchedNextEpisode = true
        // Sodalite#81: a downloaded successor plays from the device whichever way this one plays.
        // Without one, a local session goes to the server only while it answers.
        if let store = downloadStore,
           let local = Self.nextDownloadedEpisode(
               after: item, in: store.items.values.filter { store.completedItem($0.id) != nil }) {
            pendingLocalSuccessor = local
            nextEpisode = local.snapshot.item
            return
        }
        if isLocalSession, serverReachability() != .reachable { return }
        Task { await fetchNextEpisode() }
    }

    static func nextDownloadedEpisode(after item: JellyfinItem, in pool: [DownloadedItem]) -> DownloadedItem? {
        guard let series = item.seriesId, let season = item.parentIndexNumber, let index = item.indexNumber else { return nil }
        return pool
            .filter { $0.snapshot.item.seriesId == series && $0.manifest.state != .queued }
            .compactMap { d -> (DownloadedItem, Int, Int)? in
                guard let s = d.snapshot.item.parentIndexNumber, let i = d.snapshot.item.indexNumber else { return nil }
                return (s, i) > (season, index) ? (d, s, i) : nil
            }
            .min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }


    private func fetchNextEpisode() async {
        guard let seriesID = item.seriesId else { return }

        // Snapshot identifiers up front in case `item` mutates mid-await.
        let currentID = item.id
        let currentIndex = item.indexNumber
        let currentSeasonID = item.seasonId

        // Strict physical ordering, deliberately NOT Jellyfin's NextUp: NextUp returns the next *unwatched* episode series-wide, skipping partly-watched seasons (S1E5 -> S3E1 over a partial S2). Auto-advance must move to the physically next episode.
        guard let currentSeasonID, let currentIndex else { return }

        do {
            // 1. Next episode in the current season: lowest indexNumber strictly greater than the current one.
            let episodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: currentSeasonID, userID: userID
            )
            if let candidate = episodes
                .filter({ $0.id != currentID })
                .filter({ ($0.indexNumber ?? -1) > currentIndex })
                .min(by: { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }) {
                // Episode may have been switched via the picker mid-fetch; a stale result would seed the OLD episode's successor.
                guard item.id == currentID else { return }
                nextEpisode = candidate
                return
            }

            // 2. End of season: roll over to the first episode of the next season by indexNumber. Lowest season index strictly greater than current skips Specials (season 0), so a finale advances to S2E1, not Specials.
            let seasons = try await playbackService.getSeasons(
                seriesID: seriesID, userID: userID
            )
            guard let currentSeasonIndex = seasons
                .first(where: { $0.id == currentSeasonID })?.indexNumber,
                  let nextSeason = seasons
                .filter({ ($0.indexNumber ?? -1) > currentSeasonIndex })
                .min(by: { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) })
            else { return }

            let nextSeasonEpisodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: nextSeason.id, userID: userID
            )
            if let firstEpisode = nextSeasonEpisodes
                .min(by: { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }) {
                guard item.id == currentID else { return }
                nextEpisode = firstEpisode
            }
        } catch {
            #if DEBUG
            print("[NextEpisode] Fetch failed: \(error)")
            #endif
        }
    }

    /// Warms the successor's source shortly before the switch (AetherEngine#551).
    ///
    /// Two costs sit at that seam and this removes both. The switch drops the cached PlaybackInfo,
    /// so the next episode asks the server for it again while the viewer waits, and the engine then
    /// opens a cold source, which on a non-fast-start MP4 is two to three sequential round trips
    /// before the first sample read. Fetching the response here keeps it for the switch, and the URL
    /// it yields is warmed on the same pass.
    ///
    /// Not armed when the successor is first known, which is at the first frame: a PlaybackInfo
    /// response would be forty minutes old by the time it was used, and the warmed bytes would sit
    /// in memory for all of it. `successorWarmLeadSeconds` is where that trade is written down.
    func warmSuccessorIfDue(remainingSeconds: Double) {
        guard !hasWarmedSuccessor, !isLiveSession, let next = nextEpisode else { return }
        guard NextEpisodePolicy.shouldWarmSuccessor(
            outroStartSeconds: outroSegment?.startSeconds,
            sourceTime: player.sourceTime,
            remainingSeconds: remainingSeconds
        ) else { return }
        hasWarmedSuccessor = true
        Task { [weak self] in await self?.warmSuccessor(next) }
    }

    func warmSuccessor(_ next: JellyfinItem) async {
        // A downloaded successor needs no PlaybackInfo and no stream to warm.
        if pendingLocalSuccessor?.id == next.id { return }
        // Read once, before the await: a rung picked while this is in flight must not relabel a
        // response fetched at the old cap.
        let quality = effectiveStreamingQuality
        guard let info = try? await playbackService.getPlaybackInfo(
            itemID: next.id, userID: userID,
            profile: DirectPlayProfile.current(maxStreamingBitrate: quality.maxStreamingBitrate)
        ) else { return }
        // Minutes pass at most, but the successor can still move underneath this: an episode picked
        // from the season list replaces it, and a response naming the old one would then put its
        // source id under the new item's path, which the server answers with a 400 (Sodalite#71).
        guard nextEpisode?.id == next.id else { return }
        cachedPlaybackInfo = PrefetchedPlaybackInfo(itemID: next.id, quality: quality, response: info)
        guard let source = PlaybackStreamSelection.defaultSource(in: info) else { return }
        await PlaybackStreamSelection.warm(itemID: next.id, source: source, using: playbackService)
    }

    /// Starts the auto-advance timer. `from` is always clock-derived (`NextEpisodePolicy.countdownStart`),
    /// so it can never outlive the source; no default, a call site that forgets it is a compile error
    /// rather than a silent return of the old fixed length.
    func startNextEpisodeCountdown(from seconds: Int) {
        // Autoplay off: still show the overlay for manual pick, but skip the auto-transition timer.
        // Countdown off (Sodalite#67): same here, and the switch happens at end-of-media instead, so
        // credits and post-credit scenes play out in full.
        guard preferences.autoplayNextEpisode, preferences.autoplayCountdown else {
            // Written only on change: with no timer to take ownership the clock sink calls this on
            // every tick while the card is up, and Observation invalidates on the write, not on the
            // value, so a blind assignment would re-render the overlay 10x a second through the credits.
            if isCountdownActive { isCountdownActive = false }
            if nextEpisodeCountdown != 0 { nextEpisodeCountdown = 0 }
            return
        }

        // PiP on the NATIVE backend: advance immediately (invisible countdown; the 5.12.0 in-place
        // item handover keeps the window alive through the swap). SW backend (Phase A): the reload
        // rebuilds renderer+layer and would kill the window, so no auto-advance; the episode runs
        // out and onPiPContentEnded closes the window (layer-stable reload is Phase B).
        if player.pictureInPictureActive {
            isCountdownActive = false
            nextEpisodeCountdown = 0
            nextEpisodeTimer?.cancel()
            nextEpisodeTimer = nil
            guard pipCanAdvanceCurrentBackend else {
                LogTap.shared.note("[NextEp] pip active, backend cannot advance in place")
                return
            }
            LogTap.shared.note("[NextEp] pip active, advancing immediately")
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
            return
        }

        nextEpisodeCountdown = max(1, seconds)
        nextEpisodeCountdownTotal = nextEpisodeCountdown
        isCountdownActive = true
        nextEpisodeTimer?.cancel()
        LogTap.shared.note("[NextEp] countdown_start from=\(nextEpisodeCountdown)s nextId=\(nextEpisode?.id ?? "nil")")
        // [weak self]: the engine outlives the VM, the countdown timer must not.
        nextEpisodeTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.nextEpisodeCountdown > 0 else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.nextEpisodeCountdown -= 1
            }
            guard !Task.isCancelled, self != nil else { return }
            LogTap.shared.note("[NextEp] countdown_fired")
            // New task: calling playNextEpisode() directly would let a nextEpisodeTimer cancel propagate into player.load (CancellationError).
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
        }
    }

    func playNextEpisode() async {
        guard let next = nextEpisode else {
            LogTap.shared.note("[NextEp] playNextEpisode: bailing, nextEpisode is nil")
            return
        }
        // Second latch behind stopPlayback's timer cancel: a countdown firing into a torn-down session must not load on the shared engine behind a dismissed player (startPlayback resets isTearingDown at entry).
        guard !isTearingDown else {
            LogTap.shared.note("[NextEp] playNextEpisode: bailing, session is tearing down")
            return
        }
        LogTap.shared.note("[NextEp] playNextEpisode enter: from=\(item.id) to=\(next.id)")
        // Queue: advance the cursor so the next resolveNextEpisode seeds from the entry after the one we're loading. resetSessionState deliberately leaves playQueue/queueIndex untouched.
        if isQueuePlayback {
            queueIndex += 1
        }
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false

        stopProgressReporting()
        cancellables.removeAll()

        // Fire-and-forget stop report: reportStop's 30s URLRequest timeout would otherwise stall the transition behind a hidden, spinner-less overlay on a server hiccup.
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: completionAwarePositionTicks,
            liveStreamId: nil
        )
        recordLocalProgress(positionTicks: stopReport.positionTicks, played: hasReachedEndOfContent)
        let svc = playbackService
        Task {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                NotificationCenter.default.post(
                    name: .playbackProgressDidChange,
                    object: nil,
                    userInfo: [
                        PlaybackProgressKey.itemID: stopReport.itemId,
                        PlaybackProgressKey.positionTicks: stopReport.positionTicks
                    ]
                )
                LogTap.shared.note("[NextEp] report_stop_done (background)")
            } catch {
                LogTap.shared.note("[NextEp] report_stop_failed (background): \(error.localizedDescription)")
            }
        }

        // Do NOT call player.stop(): a full stop tears down the native AVPlayer, and AVKit fails to re-register its Now-Playing session against a swapped player, blanking the CC widget (issue #15). engine.load(newURL) reloads in place, preserving the AVPlayer across the seam.
        LogTap.shared.note("[NextEp] reload_in_place (no engine stop)")

        resetSessionState(switchingTo: next)

        LogTap.shared.note("[NextEp] start_playback_enter id=\(item.id)")
        await startPlayback()
        LogTap.shared.note("[NextEp] start_playback_exit error=\(errorMessage ?? "nil") isPlaying=\(isPlaying)")
    }

    /// Shared per-session reset for both episode-switch paths (auto-advance + season picker). Single owner on purpose: the two inline copies had drifted once (a stray player.stop() in the picker path, breaking the issue-#15 AVPlayer-reuse design).
    private func resetSessionState(switchingTo newItem: JellyfinItem) {
        item = newItem
        localDownload = pendingLocalSuccessor?.id == newItem.id ? pendingLocalSuccessor : nil
        pendingLocalSuccessor = nil
        // Single choke point for every in-session item switch (auto-advance, queue, season picker), so
        // the detail view behind the player can follow along and backing out lands on the episode that
        // was actually watched instead of the one that was started.
        NotificationCenter.default.post(
            name: .playerDidSwitchItem,
            object: nil,
            userInfo: [PlayerItemSwitchKey.item: newItem]
        )
        startFromBeginning = true
        // A response the successor warm fetched for THIS item is the one thing worth carrying across
        // the switch: it is exactly what the seam would otherwise ask the server for again while the
        // viewer waits on a black screen. Anything naming another item still goes, for the reason
        // `startPlayback` states where it reads this.
        if cachedPlaybackInfo?.matching(newItem.id, quality: effectiveStreamingQuality) == nil {
            cachedPlaybackInfo = nil
        }
        errorMessage = nil
        videoFormat = .sdr
        clearVideoFormatAnnouncement()
        subtitleCues = []
        subtitleStreams = []
        externalEngineTrackIDs = [:]
        activeSubtitleIndex = nil
        activeAudioIndex = nil
        // The in-place AVPlayer reload (issue #15) resumes the next item at 1.0x; reset to the
        // 1.0x index so the speed badge/picker match the engine instead of the prior episode's rate.
        activeSpeedIndex = 2
        // This path bypasses teardown() for AVPlayer reuse (issue #15), so deactivate explicitly: stale ASS script and subtitle-search overlay would otherwise survive onto the next episode.
        deactivateASSRendering()
        dismissSubtitleSearch()
        subtitleDeleteState = .hidden
        activeSubtitleCodec = nil
        // Silent forced fallback is per-item (streams + audio language); the next load re-resolves it.
        forcedSubtitleFallback = .none
        didAttemptReplacedItemRecovery = false
        nextEpisode = nil
        hasFetchedNextEpisode = false
        hasWarmedSuccessor = false
        nextEpisodeCancelled = false
        nextEpisodeOverlayDismissed = false
        nextEpisodeCountdown = 10
        isCountdownActive = false
        hasReportedStart = false
        hasStartedPlaying = false
        showControls = false
        isScrubbing = false
        controlsFocus = .progressBar
        trackDropdown = .none
        progress = 0
        playbackTime = 0
        resumePositionTicks = 0
        introSegment = nil
        outroSegment = nil
        recapSegment = nil
        activeSkipSegment = nil
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentRecap = false
        didAutoSkipCurrentOutro = false
        didSkipCurrentSegment = nil
    }

    func cancelNextEpisode() {
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false
        isCountdownActive = false

        // Cancelling after the source already finished (overlay shown from the .ended handler, or
        // autoplay off so it just parks there) leaves an engine session that is terminal: seek and
        // play are both no-ops in `.ended`. Close like any other end-of-content instead of handing
        // back a frozen last frame, and take it as a rejected successor.
        if hasStartedPlaying, player.state == .ended {
            nextEpisodeCancelled = true
            onPlaybackReachedEnd?()
            return
        }
        // Still running: this only clears the card off the credits. The advance survives it and fires
        // at the real end of the episode (Sodalite#67); with autoplay off there is nothing to survive,
        // and end-of-media routes the dismissal as a rejection.
        nextEpisodeOverlayDismissed = true
    }

    /// Tear down overlay + countdown when the user scrubs back out of the end-window. Unlike `cancelNextEpisode` it does NOT set `nextEpisodeCancelled = true`, so the overlay re-triggers naturally on playing forward again.
    func resetNextEpisodeOverlayState() {
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false
        isCountdownActive = false
        nextEpisodeCountdown = 10
    }

    // MARK: - Season Episode Picker

    /// Loads the current season's episodes (sorted by indexNumber) into `seasonEpisodes` for the transport-bar picker. No-ops for items without a series + season.
    func loadSeasonEpisodes() async {
        guard let seriesID = item.seriesId,
              let seasonID = item.seasonId else {
            seasonEpisodes = []
            return
        }
        do {
            let episodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: seasonID, userID: userID
            )
            seasonEpisodes = episodes.sorted { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
        } catch {
            #if DEBUG
            print("[SeasonPicker] Fetch failed: \(error)")
            #endif
            seasonEpisodes = []
        }
    }

    /// Switches playback to a season-list episode, mirroring the playNextEpisode flow (same reset surface + reportStop/reportStart cycle). Bounds-checked so a stale dropdown highlight can't crash.
    func selectEpisode(at index: Int) async {
        guard seasonEpisodes.indices.contains(index) else { return }
        let target = seasonEpisodes[index]
        guard target.id != item.id else { return }

        // Manual pick breaks the shuffle queue: revert to ordinary series auto-advance from here on.
        playQueue = []
        queueIndex = 0

        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false

        stopProgressReporting()
        cancellables.removeAll()

        // Fire-and-forget stop report (mirrors playNextEpisode): reportStop's 30s timeout would leave the picker row unresponsive on a slow CDN (DrHurt #12).
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: completionAwarePositionTicks,
            liveStreamId: nil
        )
        recordLocalProgress(positionTicks: stopReport.positionTicks, played: hasReachedEndOfContent)
        let svc = playbackService
        Task {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                NotificationCenter.default.post(
                    name: .playbackProgressDidChange,
                    object: nil,
                    userInfo: [
                        PlaybackProgressKey.itemID: stopReport.itemId,
                        PlaybackProgressKey.positionTicks: stopReport.positionTicks
                    ]
                )
                LogTap.shared.note("[SeasonPicker] report_stop_done (background)")
            } catch {
                LogTap.shared.note("[SeasonPicker] report_stop_failed (background): \(error.localizedDescription)")
            }
        }

        // No player.stop() (mirrors playNextEpisode): engine.load(newURL) reloads in place so AVKit's Now-Playing session survives the seam (issue #15).
        resetSessionState(switchingTo: target)

        await startPlayback()
    }
}
