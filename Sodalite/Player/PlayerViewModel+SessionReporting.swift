import Foundation
import AetherEngine

extension PlayerViewModel {

    /// Sodalite#81: every position the server would get also lands in the manifest, online or not.
    func recordLocalProgress(positionTicks: Int64, played: Bool) {
        guard let local = localDownload, let store = downloadStore, positionTicks > 0 || played else { return }
        let now = Date()
        try? store.update(itemID: local.id) {
            $0.progress.positionTicks = played ? 0 : positionTicks
            $0.progress.played = $0.progress.played || played
            $0.progress.lastPlayed = now
        }
    }

    /// Position in Jellyfin ticks from playbackTime (survives player.stop(),
    /// unlike player.currentTime). Falls back to resumePositionTicks only when
    /// playbackTime == 0; NOT max(ticks, resumePositionTicks), which clamped a
    /// rewind past the resume point back up so Jellyfin never recorded it.
    var currentPositionTicks: Int64 {
        let ticks = Int64(playbackTime * 10_000_000)
        return ticks > 0 ? ticks : resumePositionTicks
    }

    /// The playhead sits where the episode is over as far as the viewer is concerned: at or past the
    /// outro marker, or inside the no-marker end window. Live has no end to reach.
    var hasReachedEndOfContent: Bool {
        guard !isLiveSession, hasStartedPlaying else { return false }
        return NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: outroSegment?.startSeconds,
            sourceTime: player.sourceTime,
            remainingSeconds: effectiveDuration > 0 ? effectiveDuration - playbackTime : .infinity
        )
    }

    /// What a stop report should carry, given where the playhead is. See `PlaybackCompletionReport`:
    /// Jellyfin files an item as played from this number alone, and an outro marker on a show with
    /// minutes of credits sits below the line it compares against.
    var completionAwarePositionTicks: Int64 {
        PlaybackCompletionReport.positionTicks(
            playhead: currentPositionTicks,
            runtimeTicks: item.runTimeTicks,
            reachedEndOfContent: hasReachedEndOfContent
        )
    }

    func reportStart() async {
        guard !hasReportedStart else { return }
        hasReportedStart = true
        let ticks = currentPositionTicks
        let report = PlaybackStartReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: ticks,
            canSeek: true,
            playMethod: activePlayMethod,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        do {
            try await playbackService.reportPlaybackStart(report)
        } catch {
            #if DEBUG
            print("[SessionReport] Start FAILED: \(error)")
            #endif
        }
    }

    func reportProgress() async {
        let ticks = currentPositionTicks
        guard ticks > 0 else { return } // Don't report position 0
        recordLocalProgress(positionTicks: ticks, played: false)
        let report = PlaybackProgressReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: ticks,
            isPaused: !isPlaying,
            canSeek: true,
            playMethod: activePlayMethod,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        do {
            try await playbackService.reportPlaybackProgress(report)
        } catch {
            #if DEBUG
            print("[SessionReport] Progress FAILED: \(error)")
            #endif
        }
    }

    func reportStop(positionTicks: Int64? = nil, liveStreamID: String? = nil) async {
        // positionTicks override lets stopPlayback() capture position BEFORE
        // killing the engine (stop audio first, no trailing buffer on dismiss).
        // liveStreamID closes a dead tuner on retune (belt-and-braces with
        // the explicit closeLiveStream).
        let ticks = positionTicks ?? completionAwarePositionTicks
        let report = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: ticks,
            liveStreamId: liveStreamID
        )
        do {
            try await playbackService.reportPlaybackStopped(report)
            // Payload lets detail/Home patch this item's resume position in
            // place, race-free, instead of re-fetching (issue #24).
            NotificationCenter.default.post(
                name: .playbackProgressDidChange,
                object: nil,
                userInfo: [
                    PlaybackProgressKey.itemID: item.id,
                    PlaybackProgressKey.positionTicks: ticks
                ]
            )
            // Inside the do: a failed report means the server never learned the new
            // position, so the shelf has nothing new to fetch.
            TopShelfRefresher.invalidate()
        } catch {
            #if DEBUG
            print("[SessionReport] Stop FAILED: \(error)")
            #endif
        }
    }

    func startProgressReporting() {
        progressTimer?.cancel()
        progressTimer = nil
        // Every caller reaches this across an await (reportStart), and stopPlayback may have run in
        // that gap: a timer armed now would outlive the session and keep rewriting its position.
        guard !isTearingDown else { return }
        progressTimer = Task { [weak self] in
            // Wait for the first time update, then report so short views track.
            var delay: Duration = .seconds(2)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                delay = .seconds(10)
                guard !Task.isCancelled else { return }
                // Re-resolved per tick, so the timer never keeps a dismissed view model alive.
                guard let self, !self.isTearingDown else { return }
                await self.reportProgress()
            }
        }
    }

    /// Report progress on pause/seek. Task handle is tracked so stopPlayback()
    /// can cancel an orphaned report after dismiss on a slow CDN.
    func reportProgressIfNeeded() {
        progressReportOnDemandTask?.cancel()
        progressReportOnDemandTask = Task { @MainActor [weak self] in
            await self?.reportProgress()
        }
    }

    func stopProgressReporting() {
        progressTimer?.cancel()
        progressTimer = nil
    }
}
