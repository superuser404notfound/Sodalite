import Foundation
import Combine
import AVFoundation
import MediaPlayer
import AetherEngine

/// Owns music playback end-to-end: queue, transport, the shared `AetherEngine` audio-only backend,
/// audio session, Jellyfin session reporting, and the music -> video handoff teardown. Mirrors
/// `PlayerViewModel`: `@MainActor @Observable`, Combine sinks on the engine's `@Published`, fire-and-forget reports.
///
/// The engine (`DependencyContainer.playerEngine`) is a process-wide singleton shared with the video
/// player. A video load while a music queue is live triggers the engine's own `stopInternal`, tearing
/// down the audio host; this coordinator watches `playbackBackend` leave `.audio` and clears its own
/// state WITHOUT re-stopping the engine (it has already moved on).
///
/// System Now-Playing is driven by the `+NowPlaying` extension via a per-player `MPNowPlayingSession`;
/// applyNowPlayingInfo / clearNowPlayingInfo fire at every track-change / play-pause / seek.
@MainActor
@Observable
final class MusicPlaybackCoordinator {
    // Non-private because the +NowPlaying extension (separate file) accesses them.
    let engine: AetherEngine
    private let playbackService: JellyfinPlaybackServiceProtocol
    let imageService: JellyfinImageService
    private let userIDProvider: () -> String?
    /// A track from another server in a combined setup is streamed from, and reported to, its own
    /// server as that server's user (Sodalite#85). nil means the active server.
    private let secondaryRoute: (JellyfinItem) -> (service: JellyfinPlaybackServiceProtocol, userID: String)?

    private(set) var queue: [JellyfinItem] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// Whether the fullscreen Now-Playing screen is up, and which view presents it. Shared rather
    /// than router-local: with the sidebar the router cannot present over an album cover, so the
    /// cover hosts the player itself (see NowPlayingPresentation).
    let nowPlayingPresentation = NowPlayingPresentation()

    // MARK: - Scrubbing (see +Scrubbing)

    /// True while the user is scrubbing the fullscreen player's progress bar
    /// (touchpad pan, left/right skip, or a held spool). The bar shows
    /// `scrubProgress` instead of the live position while this is set.
    var isScrubbing = false
    /// The previewed scrub position as a 0...1 fraction of the duration.
    var scrubProgress: Double = 0
    /// The in-flight continuous (hold-to-seek) spool task; non-nil while a
    /// left/right press is held.
    var continuousSeekTask: Task<Void, Never>?

    var currentItem: JellyfinItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }
    var hasNext: Bool { currentIndex + 1 < queue.count }
    var hasPrevious: Bool { currentIndex > 0 }

    // MARK: - Session reporting bookkeeping

    private var playSessionId: String?
    private var currentMediaSourceId: String?
    private var lastProgressReport: Date = .distantPast
    /// The single in-flight track load; each transport action cancels the previous first.
    /// loadAndPlayCurrent suspends on a network fetch before engine.load, so two rapid Next presses
    /// would race their fetches and the LAST to resolve would win the engine while currentIndex / Now
    /// Playing describe the other track.
    private var loadTask: Task<Void, Never>?
    /// Load generation, checked after every await so a superseded load can't write its session ids /
    /// now-playing over the newer track's.
    private var loadGeneration = 0
    /// Distinguishes a user-driven stop / music->video handoff from a natural track end. Latched true
    /// before any teardown so the `$state` sink doesn't mistake the stop for end-of-track (`.ended`) and recursively advance.
    private var isStopping: Bool = false
    private var cancellables = Set<AnyCancellable>()
    /// The 2 s now-playing refresh; non-nil only while a queue is live.
    private var nowPlayingKeepAlive: AnyCancellable?

    /// Now-Playing bookkeeping (see +NowPlaying). registeredCommandCenterID = the MPRemoteCommandCenter
    /// the handlers are bound to; the resolved center flips per track between session (AVPlayer) and
    /// shared default (FFmpeg). nowPlayingArtworkItemID = item id at artwork-load start, compared on completion to drop stale artwork.
    var registeredCommandCenterID: ObjectIdentifier?
    var nowPlayingArtworkItemID: String?
    /// Cached current-track artwork so a state/duration refresh keeps showing it instead of flashing
    /// empty mid-load. Both paths use it: the AVPlayer path stages it into AVPlayerItem.nowPlayingInfo,
    /// the FFmpeg fallback writes it to the shared center. Cleared on stop / track change.
    var cachedArtwork: MPMediaItemArtwork?
    var cachedArtworkItemID: String?

    /// Minimum spacing between fire-and-forget progress reports.
    private static let progressReportInterval: TimeInterval = 10

    init(engine: AetherEngine,
         playbackService: JellyfinPlaybackServiceProtocol,
         imageService: JellyfinImageService,
         userIDProvider: @escaping () -> String?,
         secondaryRoute: @escaping (JellyfinItem) -> (service: JellyfinPlaybackServiceProtocol, userID: String)? = { _ in nil }) {
        self.engine = engine
        self.playbackService = playbackService
        self.imageService = imageService
        self.userIDProvider = userIDProvider
        self.secondaryRoute = secondaryRoute
        subscribeToEngine()
    }

    /// Album / playlist the queue started from, shown as the player title (per-track title is in the queue).
    private(set) var contextTitle: String?

    // MARK: - Public transport

    /// Replace the queue and start at `index` (clamped, so a raw tap position is safe). `contextTitle`
    /// is the player heading. Also requests the fullscreen Now-Playing screen.
    func play(queue items: [JellyfinItem], startAt index: Int, contextTitle: String? = nil) {
        // An empty queue would present a stuck "Nothing Playing" player (dismiss onChange never fires
        // since currentItem never changes). Reachable via album views whose getSongs failed into [].
        guard !items.isEmpty else { return }
        reportStopped()
        self.contextTitle = contextTitle
        queue = items
        currentIndex = max(0, min(index, items.count - 1))
        requestNowPlayingPresentation()
        startLoadingCurrent()
    }

    /// Jump to another track in the CURRENT queue, keeping queue + context title intact.
    func skip(toQueueIndex index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        reportStopped()
        currentIndex = index
        startLoadingCurrent()
    }

    /// Put the fullscreen Now-Playing screen on screen (the card resumes, not restarts).
    func requestNowPlayingPresentation() {
        nowPlayingPresentation.present()
    }

    func togglePlayPause() {
        // Reactivate the audio session before a resume (see resume()).
        if !isPlaying { configureAudioSessionIfNeeded() }
        engine.togglePlayPause()
        // isPlaying / now-playing refresh come from the engine state sink.
    }

    /// Resume playback, reactivating the audio session first: the system may have deactivated it on
    /// pause, after which AVPlayer.play() yields no audio. Used by the remote/CC play command.
    func resume() {
        configureAudioSessionIfNeeded()
        engine.play()
    }

    /// Advance, or stop if exhausted. Reports PlaybackStopped for the outgoing track BEFORE mutating
    /// currentIndex: Jellyfin marks items played / bumps play counts off the stop report, so without
    /// this only the final track of a session registered in play history.
    func next() {
        if hasNext {
            reportStopped()
            currentIndex += 1
            startLoadingCurrent()
        } else {
            stop()
        }
    }

    /// Standard "previous": >3 s in (or nothing before) restarts the current track, else steps back.
    func previous() {
        if currentTime > 3 || !hasPrevious {
            // Restart-in-place: source is loaded, so seek is instant and keeps the play session (a
            // full loadAndPlayCurrent would re-fetch + reload for an audible gap). Explicit play()
            // after, since restarting from paused must resume (seek alone parks the engine at 0).
            Task {
                await engine.seek(to: 0)
                engine.play()
            }
            applyNowPlayingInfo()
        } else {
            reportStopped()
            currentIndex -= 1
            startLoadingCurrent()
        }
    }

    func seek(to seconds: Double) {
        Task { await engine.seek(to: seconds) }
        applyNowPlayingInfo()
    }

    /// User-driven stop. Latches `isStopping` first so the engine's `.idle` (then `.none`) transition
    /// is not mistaken for a natural track end / handoff and does not recursively fire.
    func stop() {
        isStopping = true
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        reportStopped()
        engine.stop()
        queue = []
        currentIndex = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        playSessionId = nil
        currentMediaSourceId = nil
        stopNowPlayingKeepAlive()
        clearNowPlayingInfo()
        isStopping = false
    }

    // MARK: - Load + play

    /// Cancel any in-flight load and load the current track. Single entry point for every transport
    /// action so loads are strictly serialized; see `loadTask`.
    private func startLoadingCurrent() {
        // The previous track's ids until PlaybackInfo answers for this one; a stop reported in that
        // window would pair the new item with the old session and the old playhead.
        currentMediaSourceId = nil
        playSessionId = nil
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.loadAndPlayCurrent(generation: generation)
            guard let self, self.loadGeneration == generation else { return }
            self.loadTask = nil
        }
    }

    private func loadAndPlayCurrent(generation: Int) async {
        guard let item = currentItem else { return }
        let route = secondaryRoute(item)
        guard let userID = route?.userID ?? userIDProvider() else { return }
        let playbackService = route?.service ?? self.playbackService

        configureAudioSessionIfNeeded()

        do {
            let info = try await playbackService.getPlaybackInfo(
                itemID: item.id,
                userID: userID,
                profile: nil
            )
            // Superseded while fetching (rapid Next, stop, handoff): a newer load owns the engine + bookkeeping.
            guard generation == loadGeneration else { return }
            guard let source = info.mediaSources.first else {
                LogTap.shared.note("[MusicCoordinator] no media source for \(item.name)")
                return
            }
            currentMediaSourceId = source.id
            playSessionId = info.playSessionId

            guard let url = playbackService.buildAudioStreamURL(
                itemID: item.id,
                mediaSourceID: source.id,
                container: source.container,
                isStatic: true
            ) else {
                LogTap.shared.note("[MusicCoordinator] could not build audio URL for \(item.name)")
                return
            }

            // Clear the stopping latch on a fresh load so the end-of-track / handoff sinks arm for
            // this track. Here (not earlier) so a load failure leaves the latch as-is.
            isStopping = false

            try await engine.load(
                url: url,
                startPosition: nil,
                options: LoadOptions(audioOnly: true)
            )
            guard generation == loadGeneration else { return }

            // Publish now-playing + register remote commands BEFORE the first play(): tvOS only
            // registers the app as the system Now-Playing source (and flips the Siri Remote to a play
            // affordance) when the info center is populated and handlers bound ahead of playback (WWDC17 S251).
            applyNowPlayingInfo()
            engine.play()
            startNowPlayingKeepAlive()

            reportStart()
        } catch is CancellationError {
            // Our own supersession (loadTask.cancel() or engine generation bump); newer load owns state.
            return
        } catch {
            guard generation == loadGeneration else { return }
            LogTap.shared.note("[MusicCoordinator] load failed for \(item.name): \(error)")
            // Leave state sane: don't advance, don't flip isPlaying true.
            isPlaying = false
        }
    }

    /// Ensure the audio session is active. Before every load and resume, NOT one-time gated: the
    /// system can deactivate on pause, after which AVPlayer.play() yields no audio until reactivated.
    /// setCategory/setActive are idempotent, so repeated calls are cheap.
    private func configureAudioSessionIfNeeded() {
        #if os(macOS)
        // There is no app-level audio session on a Mac: output is the device's, and AVPlayer plays
        // into it without being asked.
        #else
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            LogTap.shared.note("[MusicCoordinator] audio session active, category=\(session.category.rawValue)")
        } catch {
            LogTap.shared.note("[MusicCoordinator] audio session setup FAILED: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Engine observation

    private func subscribeToEngine() {
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.currentTime = time
                // Throttle progress reports to at most one per interval.
                let now = Date()
                if now.timeIntervalSince(self.lastProgressReport) >= Self.progressReportInterval {
                    self.lastProgressReport = now
                    self.reportProgress()
                }
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                guard let self else { return }
                guard dur > 0, dur != self.duration else { return }
                self.duration = dur
                // AVPlayer publishes duration async after the item is ready, so the now-playing set
                // at track load had duration 0; refresh so system UI shows the right length / progress.
                self.applyNowPlayingInfo()
            }
            .store(in: &cancellables)

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = (state == .playing)
                // Refresh now-playing on a play/pause transition so native rate / elapsed match.
                if self.isPlaying != wasPlaying {
                    self.applyNowPlayingInfo()
                }

                // Natural end-of-track: the engine reaches `.ended` when the source runs out (#63;
                // user-driven stop latches isStopping and drives `.idle`, so matching `.ended` is exact).
                // Only treat it as such when we didn't initiate the stop, a queue is live, AND no load
                // is in flight: a Next racing the natural end already advanced but its load only leaves
                // the terminal state after the fetch, so without the loadTask gate it double-advances.
                if state == .ended, !self.isStopping, !self.queue.isEmpty, self.loadTask == nil {
                    if self.hasNext {
                        self.next()
                    } else {
                        self.stop()
                    }
                }
            }
            .store(in: &cancellables)

        engine.$playbackBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] backend in
                guard let self else { return }
                // Music -> video handoff: a video load flips the backend to `.native`/`.software`.
                // The engine already tore the audio host down via stopInternal, so clear OUR state
                // WITHOUT engine.stop() (that would stop the video that took over). Gated on the video
                // backends so our own stop()'s `.audio -> .none` doesn't re-enter here.
                guard backend == .native || backend == .software else { return }
                guard !self.queue.isEmpty else { return }
                self.isStopping = true
                // A music load still in flight must not finish into the engine after the handoff.
                self.loadTask?.cancel()
                self.loadTask = nil
                self.loadGeneration += 1
                self.reportStopped()
                self.queue = []
                self.currentIndex = 0
                self.isPlaying = false
                self.currentTime = 0
                self.duration = 0
                self.playSessionId = nil
                self.currentMediaSourceId = nil
                self.stopNowPlayingKeepAlive()
                self.clearNowPlayingInfo()
                self.isStopping = false
            }
            .store(in: &cancellables)

        // Re-publish now-playing on foreground/background. tvOS sources the Home Now-Playing badge
        // from an update landing around the background transition; if the last write was while
        // foreground (music started before minimizing) the badge never appears. Re-publishing here
        // with live state gives the system a fresh entry the moment the app backgrounds.
        NotificationCenter.default.publisher(for: AppActivity.didLeaveForeground)
            .merge(with: NotificationCenter.default.publisher(for: AppActivity.didBecomeActive))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentItem != nil else { return }
                self.applyNowPlayingInfo()
            }
            .store(in: &cancellables)

    }

    /// Keep the system now-playing entry fresh while a track is loaded (playing OR paused). tvOS
    /// renders the Home overlay from a recent entry and drops a stale one, so without this the badge
    /// lags ~2s behind our last write and a pause drops the overlay + remote play route. Light 2s
    /// elapsed/rate refresh; started on first load, cancelled with the session (the coordinator is
    /// process-lifetime, and an always-on timer was a permanent 0.5 Hz wakeup even when idle).
    private func startNowPlayingKeepAlive() {
        guard nowPlayingKeepAlive == nil else { return }
        nowPlayingKeepAlive = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.currentItem != nil else { return }
                self.refreshNowPlayingElapsed()
            }
    }

    private func stopNowPlayingKeepAlive() {
        nowPlayingKeepAlive?.cancel()
        nowPlayingKeepAlive = nil
    }

    // MARK: - Jellyfin session reporting

    private var positionTicks: Int64 { Int64(currentTime * 10_000_000) }

    private func reportStart() {
        guard let item = currentItem, let mediaSourceId = currentMediaSourceId else { return }
        let report = PlaybackStartReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
            canSeek: true,
            playMethod: PlayMethod.directPlay,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        let svc = secondaryRoute(item)?.service ?? playbackService
        Task { try? await svc.reportPlaybackStart(report) }
    }

    private func reportProgress() {
        guard let item = currentItem, let mediaSourceId = currentMediaSourceId else { return }
        let ticks = positionTicks
        guard ticks > 0 else { return }
        let report = PlaybackProgressReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: ticks,
            isPaused: !isPlaying,
            canSeek: true,
            playMethod: PlayMethod.directPlay,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        let svc = secondaryRoute(item)?.service ?? playbackService
        Task { try? await svc.reportPlaybackProgress(report) }
    }

    private func reportStopped() {
        guard let item = currentItem, let mediaSourceId = currentMediaSourceId else { return }
        let report = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
            liveStreamId: nil
        )
        let svc = secondaryRoute(item)?.service ?? playbackService
        Task { try? await svc.reportPlaybackStopped(report) }
    }
}
