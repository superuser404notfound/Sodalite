import Foundation
import Combine
import AetherEngine

/// How one pre-roll ended.
enum PrerollEnd: Sendable {
    case ended, skipped, failed, tornDown
}

/// Sodalite#244: the pre-rolls an intro provider (Local Intros plugin) hands out, played before the
/// movie on the same engine. Deliberately not the play queue: an intro sends no progress, no Trakt
/// scrobble, no next-episode countdown and no `.playerDidSwitchItem`, so it never shows up in
/// Continue Watching and never moves the detail page behind the player.
extension PlayerViewModel {

    /// Plays whatever pre-rolls are due for this start. False only when the session was torn down or
    /// cancelled on the way, so the caller must not load the movie.
    func playPrerollsIfDue() async -> Bool {
        let due = PrerollPolicy.shouldFetch(
            enabled: preferences.playPrerolls, itemType: item.type, isLive: isLiveSession,
            isLocal: isLocalSession, isMultiviewTile: isMultiviewTile, isQueuePlayback: isQueuePlayback,
            startFromBeginning: startFromBeginning, resumeTicks: item.userData?.playbackPositionTicks,
            hasResumeOverride: resumeOverrideSeconds != nil, alreadyConsumed: prerollsConsumed)
        prerollsConsumed = true
        guard due else { return true }

        let intros = PrerollPolicy.playable(await fetchIntros(), mainItemID: item.id)
        if Task.isCancelled || isTearingDown { return false }
        LogTap.shared.note("[Preroll] fetched n=\(intros.count) for=\(item.id)")
        guard !intros.isEmpty else { return true }

        defer { endPrerollSession() }
        for intro in intros {
            let source = intro.mediaSources?.first
            // Static: the file as it is, so no PlaybackInfo, no play session and no encode to kill.
            guard let url = playbackService.buildStreamURL(
                itemID: intro.id, mediaSourceID: source?.id ?? intro.id,
                container: source?.container, isStatic: true) else {
                LogTap.shared.note("[Preroll] end id=\(intro.id) reason=no_url")
                continue
            }
            let end = await playPreroll(intro, url: url)
            LogTap.shared.note("[Preroll] end id=\(intro.id) reason=\(end)")
            if end == .tornDown || Task.isCancelled || isTearingDown { return false }
        }
        LogTap.shared.note("[Preroll] done")
        return true
    }

    /// Skip Pre-roll: ends the current one. The next pre-roll or the movie loads in its place.
    func skipCurrentPreroll() {
        guard isPlayingPreroll, prerollWait != nil else { return }
        setActiveSkipSegment(nil)
        // The movie's PlaybackInfo takes a moment; the skipped intro must not keep talking meanwhile.
        player.pause()
        hostLoadActive = true
        finishPrerollWait(.skipped)
    }

    func finishPrerollWait(_ end: PrerollEnd) {
        guard let wait = prerollWait else { return }
        prerollWait = nil
        prerollCancellables.removeAll()
        wait.resume(returning: end)
    }

    private func playPreroll(_ intro: JellyfinItem, url: URL) async -> PrerollEnd {
        isPlayingPreroll = true
        showControls = false
        hostLoadActive = true
        LogTap.shared.note("[Preroll] start id=\(intro.id)")
        do {
            try await player.load(url: url, startPosition: nil, options: prerollLoadOptions())
        } catch is CancellationError {
            return .tornDown
        } catch {
            LogTap.shared.note("[Preroll] load_failed id=\(intro.id) error=\(error.localizedDescription)")
            return isTearingDown ? .tornDown : .failed
        }
        if Task.isCancelled || isTearingDown { return .tornDown }
        hostLoadActive = false
        setActiveSkipSegment(ActiveSkipSegment(kind: .preroll, startSeconds: 0, endSeconds: .greatestFiniteMagnitude))
        // No await between the teardown check above and arming the wait, so a stop cannot slip in
        // between and leave the wait armed with nobody to release it. A cancel (a retry or a rung
        // switch restarting the launch through beginPlayback) ends the pre-roll the same way.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prerollWait = continuation
                observePreroll()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishPrerollWait(.tornDown) }
        }
    }

    private func observePreroll() {
        // An `.ended` only counts once this intro played: the publisher replays its current value on
        // subscribe, which must not end the intro that is just starting.
        var playedThisIntro = false
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    playedThisIntro = true
                    self.isPlaying = true
                case .paused:
                    playedThisIntro = true
                    self.isPlaying = false
                case .ended:
                    if playedThisIntro { self.finishPrerollWait(.ended) }
                case .idle:
                    // The engine was torn down under the intro (a long trip to the Home screen with it
                    // paused). Our own stop and the next load both drop these sinks first, so an idle
                    // here means nothing will ever end this intro: move on instead of holding a black frame.
                    if playedThisIntro { self.finishPrerollWait(.failed) }
                case .error(let message):
                    LogTap.shared.note("[Preroll] engine_error \(message)")
                    self.finishPrerollWait(.failed)
                default:
                    break
                }
            }
            .store(in: &prerollCancellables)
        player.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeLoadingIndicator() }
            .store(in: &prerollCancellables)
        player.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeLoadingIndicator() }
            .store(in: &prerollCancellables)
    }

    /// The movie's own picture and sound choices, nothing subtitle-related and no probe cap.
    private func prerollLoadOptions() -> LoadOptions {
        LoadOptions(
            suppressDisplayCriteria: false,
            forceDolbyVisionOnNonDVDisplay: preferences.forceDolbyVisionOnNonDVDisplay,
            matchContentEnabled: Self.matchContentEnabled,
            panelIsInHDRMode: Self.panelIsInHDRMode,
            audioBridgeMode: preferences.audioBridgeMode,
            objectAudioRendering: preferences.objectAudioRendering,
            preferredAudioLanguages: effectivePreferredAudioLanguage().map { [$0] } ?? [],
            forwardBufferSegments: preferences.networkBufferDepth.forwardBufferSegments,
            audioDelaySeconds: preferences.audioDelaySeconds,
            audioShaping: preferences.audioShaping()
        )
    }

    private func endPrerollSession() {
        finishPrerollWait(.tornDown)
        setActiveSkipSegment(nil)
        isPlayingPreroll = false
        hostLoadActive = true
    }

    /// The server's answer, or none: after `PrerollPolicy.fetchTimeout`, on any error, or as soon as
    /// the launch is cancelled. Unstructured on purpose, a task group would wait for a request that
    /// ignores cancellation before it let the movie start.
    private func fetchIntros() async -> [JellyfinItem] {
        let service = playbackService
        let itemID = item.id
        let userID = userID
        let race = PrerollFetchRace()
        let fetch = Task {
            do {
                race.finish(try await service.getIntros(itemID: itemID, userID: userID))
            } catch {
                // After a timeout or a cancel this is the cancel arriving late, not a failure.
                if race.finish([]) { LogTap.shared.note("[Preroll] fetch_failed error=\(error.localizedDescription)") }
            }
        }
        let timer = Task {
            try? await Task.sleep(for: PrerollPolicy.fetchTimeout)
            if race.finish([]) { LogTap.shared.note("[Preroll] fetch_timeout") }
        }
        let intros = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            race.finish([])
        }
        fetch.cancel()
        timer.cancel()
        return intros
    }
}

/// First answer wins: the fetch, the timeout or a cancel. Callable from any thread, because a task
/// cancellation handler runs wherever the cancel came from.
nonisolated final class PrerollFetchRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [JellyfinItem]?
    private var waiter: CheckedContinuation<[JellyfinItem], Never>?

    /// True when this call decided the race.
    @discardableResult
    func finish(_ intros: [JellyfinItem]) -> Bool {
        let decided = lock.withLock { () -> (won: Bool, waiter: CheckedContinuation<[JellyfinItem], Never>?) in
            guard result == nil else { return (false, nil) }
            result = intros
            let pending = waiter
            waiter = nil
            return (true, pending)
        }
        decided.waiter?.resume(returning: intros)
        return decided.won
    }

    func value() async -> [JellyfinItem] {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> [JellyfinItem]? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
