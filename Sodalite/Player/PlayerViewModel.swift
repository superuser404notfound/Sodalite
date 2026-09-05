import Foundation
import Combine
import Observation
import AetherEngine
import SwiftAssRenderer
import AVKit
import UIKit
import os

/// Bridges AetherEngine with Jellyfin session reporting and the custom tvOS player UI.
/// Combine subscriptions observe the engine's @Published properties (no polling timers,
/// avoids AttributeGraph cycles). Split across +Scrubbing / +NextEpisode / +SessionReporting.
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - UI State

    var isLoading = true
    /// True while the host is bringing a session up (fetching playback info, calling `player.load()`, or
    /// running a live retune), independent of the engine phase. ORed with `playbackPhase` so the pre-engine
    /// load window still shows the spinner (AetherEngine#85). `didSet` keeps `isLoading` in sync. Not private:
    /// the live retune path in the `+Live` extension (separate file) drives it.
    var hostLoadActive = false {
        didSet { recomputeLoadingIndicator() }
    }
    /// Guards against stacking the live cold-transcode debounce recheck.
    private var scheduledLiveSpinnerRecheck = false
    /// The reader is fighting the source: drives the connection chip in `PlayerOverlayView`. Debounced by
    /// `connectionNoticeDelay` so a blip does not flash it, and deliberately independent of `isLoading`,
    /// which no longer covers a stall that leaves the picture running.
    var showsConnectionNotice = false
    /// True while the error on screen is a confirmed server outage, i.e. the one error worth offering a
    /// retry for (the server is expected back; nothing about the item changed).
    var canRetryAfterOutage = false
    /// One replaced-item lookup per item: the answer is the library's, so asking it twice for the same
    /// failure would only stall the error screen. Cleared per item in `resetSessionState`.
    var didAttemptReplacedItemRecovery = false
    /// Which error-screen button is highlighted. The overlay is display-only inside the player on tvOS, so
    /// the cursor lives here and `PlayerHostController`'s press handlers move it.
    var errorFocus: PlayerErrorFocus = .back
    var errorMessage: String?
    /// SF Symbol for the active error, set with `errorMessage` via `setError(from:)`.
    var errorIcon: String?
    /// Localised error headline above `errorMessage` in the overlay.
    var errorTitle: String?
    var isPlaying = false
    var showControls = false

    var currentTime: String = "00:00"
    var totalTime: String = "00:00"
    var remainingTime: String = "-00:00"
    var progress: Float = 0

    /// Fraction of the timeline whose content is cached ahead of the playhead (disk SegmentCache
    /// read-ahead on native direct play, demux frontier on the software path). Drives the buffered
    /// layer on the scrub bar. 0 on live and until a duration resolves.
    var bufferedProgress: Float = 0

    var playbackTime: Double = 0

    /// source-PTS of displayed frame, mirrored from `AetherEngine.sourceTime`; native-path
    /// AVPlayer clock = source_pts - producer.videoShiftPts, so side-demuxer cues sync off this.
    /// Equals playbackTime on the SW path.
    var subtitleTime: Double = 0

    var isScrubbing = false
    var scrubProgress: Float = 0
    var scrubTime: String = "00:00"
    var displayedProgress: Float { isScrubbing ? scrubProgress : progress }
    var scrubStartProgress: Float = 0

    var controlsFocus: ControlsFocus = .progressBar
    var trackDropdown: TrackDropdown = .none

    /// iOS child lock: when true, all touch input is disabled and PlayerLockOverlay is shown.
    /// Cross-platform property but only ever set on iOS; tvOS never engages it. Per player session
    /// (not persisted); survives an in-player episode change and a foreground reload (same VM instance).
    var isInputLocked = false

    // MARK: Subtitle search (Feature #4)

    enum SubtitleSearchState: Equatable {
        case idle
        case loading
        case results([RemoteSubtitleInfo])
        case empty
        case downloading(id: String)
        case error(String)
        /// Download POST accepted but track not attached by the time polling stopped (slow CDN).
        /// Carries the requested subtitle + pre-download stream-index snapshot so "Try again"
        /// re-checks without re-downloading. `message` is the localized pending copy.
        case downloadTimedOut(info: RemoteSubtitleInfo, before: Set<Int>, message: String)
    }

    var subtitleSearchVisible = false
    var subtitleSearchState: SubtitleSearchState = .idle
    /// 3-letter ISO language for the next search; seeded from preferred subtitle, then device language.
    var subtitleSearchLanguage: String = "eng"

    /// Highlighted element of the subtitle-search overlay. Display-only in SubtitleSearchView;
    /// driven by PlayerHostController press handlers.
    enum SubtitleSearchFocus: Equatable {
        case language(Int)   // index into subtitleSearchLanguageOptions
        case result(Int)     // index into the current results
        case retry           // the "Try again" button in the timed-out state
    }
    var subtitleSearchFocus: SubtitleSearchFocus = .language(0)

    /// Delete-confirmation flow for an external subtitle (hold-to-delete on its dropdown row).
    /// Host-driven overlay, display-only in SubtitleDeletePromptView. Feature #4.
    enum SubtitleDeleteState: Equatable {
        case hidden
        case confirm(streamIndex: Int)
        case deleting
        case error(String)
    }
    enum SubtitleDeleteButton { case cancel, delete }
    var subtitleDeleteState: SubtitleDeleteState = .hidden
    var subtitleDeleteFocus: SubtitleDeleteButton = .cancel
    var isSubtitleDeletePromptVisible: Bool {
        if case .hidden = subtitleDeleteState { return false }
        return true
    }

    enum ControlsFocus: Hashable {
        case progressBar
        case restartButton
        case skipSegmentButton
        case nextEpisodeButton
        case chapterButton
        case episodeButton
        case audioButton
        case subtitleButton
        case speedButton
        case pictureButton
        case pipButton
        case infoButton
        // Live-only "Return to Live" pill (LiveTransportBar); Up from the live scrubber when
        // behind the live edge, Select fires returnToLiveEdge(). VOD button row N/A for live.
        case returnToLiveButton
    }

    /// Stats-for-nerds side panel mount flag. While true it captures all remote presses
    /// (scroll, dismiss) so the player UI behind it stays inert.
    var showStatsOverlay: Bool = false {
        didSet {
            // Reset scroll cursor on open so the user always starts at the first section.
            if showStatsOverlay && !oldValue {
                statsSectionIndex = 0
            }
        }
    }

    /// Section-anchor cursor for the stats panel; up/down shifts it, StatsOverlayView watches
    /// via `scrollTo`. Clamped by `statsSectionAnchors.count`.
    var statsSectionIndex: Int = 0

    /// The media description the stats panel renders, resolved from the session's PlaybackInfo source with
    /// the launch item behind it. Computed in one place so the panel and the section cursor cannot disagree.
    var statsSourceFacts: PlaybackSourceFacts {
        PlaybackSourceFacts.resolve(
            session: activePlaybackSource, item: item, selectedMediaSourceID: mediaSourceID)
    }

    /// Which stats sections have content, for both the panel and the Up/Down cursor. Engine first on the
    /// video and audio gates: on a live channel and on a slim episode payload it is the only side that
    /// knows there is a track at all.
    var statsSectionAvailability: Set<Int> {
        let facts = statsSourceFacts
        let hasEngineAudio = player.audioTracks.contains { $0.id == player.activeAudioTrackIndex }
        let hasChannelDetail = liveChannel != nil || liveRoute != nil || activeLiveStreamID != nil
        return StatsSection.available(
            hasVideo: player.sourceVideoWidth > 0
                || player.sourceVideoCodecName != nil
                || facts.stream(ofType: .video) != nil,
            hasAudio: hasEngineAudio || facts.stream(ofType: .audio) != nil,
            hasSubtitle: activeSubtitleIndex != nil,
            hasSourceDetail: isLiveSession ? hasChannelDetail : facts.hasAny,
            showEngineDiagnostics: preferences.showEngineDiagnostics)
    }

    /// Ordered anchor IDs per stats section; up/down cursor jumps page through them.
    static let statsSectionAnchors: [String] = [
        "stats.section.live",       // 0: always shown when stats on
        "stats.section.playback",   // 1
        "stats.section.video",      // 2
        "stats.section.audio",      // 3
        "stats.section.subtitle",   // 4
        "stats.section.file",       // 5
        "stats.section.engine",     // 6: gated by showEngineDiagnostics
        "stats.section.buffer",     // 7: gated by showEngineDiagnostics
        "stats.section.network",    // 8: gated by showEngineDiagnostics
    ]

    enum TrackDropdown: Equatable {
        case none
        case chapter(highlighted: Int)  // index into chapters
        case episode(highlighted: Int)  // index into seasonEpisodes
        case audio(highlighted: Int)   // index into displayAudioTracks
        case subtitle(highlighted: Int) // index into subtitle items (0=Off, 1..=displaySubtitleStreams)
        case secondarySubtitle(highlighted: Int) // 0=Off, 1..=secondarySubtitleCandidates
        case speed(highlighted: Int)    // index into PlayerViewModel.speedOptions
        case picture(highlighted: Int)  // index into PlaybackPreferences.PictureMode.allCases
    }

    var isDropdownOpen: Bool { trackDropdown != .none }

    /// Playback speed choices; index 2 = 1.0x (matches native tvOS player's stepped set).
    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    var activeSpeedIndex: Int = 2

    // Tracks
    var subtitleCues: [SubtitleCue] = [] {
        didSet {
            subtitleMaxCueDuration = subtitleCues.reduce(60.0) {
                max($0, $1.endTime - $1.startTime)
            }
        }
    }
    /// Longest cue duration (floor 60s) bounding the overlay's active-cue walk-back; a fixed
    /// bound dropped long PGS cues (unbounded endTimes), engine prunes bitmap cues to 300s.
    var subtitleMaxCueDuration: Double = 60
    var activeAudioIndex: Int?
    var activeSubtitleIndex: Int?

    /// Secondary companion subtitle cues (issue #47), mirrored from `engine.secondarySubtitleCues`.
    var secondarySubtitleCues: [SubtitleCue] = [] {
        didSet {
            secondarySubtitleMaxCueDuration = secondarySubtitleCues.reduce(60.0) {
                max($0, $1.endTime - $1.startTime)
            }
        }
    }
    var secondarySubtitleMaxCueDuration: Double = 60
    var activeSecondarySubtitleIndex: Int?

    /// Audio tracks in picker order (container-default first); picker UI indexes here, not `player.audioTracks`.
    var displayAudioTracks: [TrackInfo] {
        let tracks = player.audioTracks
        return tracks.filter { $0.isDefault } + tracks.filter { !$0.isDefault }
    }

    /// Subtitle streams in picker order (Jellyfin-default first); picker UI indexes here with "Off" at 0, not `subtitleStreams`.
    var displaySubtitleStreams: [MediaStream] {
        let streams = subtitleStreams
        return streams.filter { $0.isDefault == true } + streams.filter { $0.isDefault != true }
    }

    /// Row order of the in-player subtitle menu, the one description every consumer reads: the item
    /// builders in both transport bars, the highlight navigation, the Select commit and hold-to-delete.
    /// Live drops the secondary header (a VOD feature) and the search footer (no library item to
    /// search against).
    var subtitleMenuRows: [SubtitleMenuRow] {
        SubtitleMenuLayout.rows(streams: displaySubtitleStreams,
                                supportsSecondary: !isLiveSession,
                                supportsSearch: supportsSubtitleSearch)
    }

    /// In-player subtitle-search reachability; VOD-only (live has no searchable library item).
    /// Also shows the subtitle button on files with zero tracks so the download entry exists (issue #15).
    var supportsSubtitleSearch: Bool { !isLiveSession }

    /// Streams eligible as SECONDARY track: text codecs only (bitmap can't stack as a companion line),
    /// never the active primary. Picker order matches `displaySubtitleStreams`.
    var secondarySubtitleCandidates: [MediaStream] {
        let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvbsub", "dvb_subtitle", "dvdsub", "dvd_subtitle", "xsub"]
        return displaySubtitleStreams.filter { stream in
            if stream.index == activeSubtitleIndex { return false }
            let codec = stream.codec?.lowercased() ?? ""
            return !bitmapCodecs.contains(codec)
        }
    }

    /// Current season's episodes sorted by indexNumber, populated lazily after startPlayback for
    /// the transport-bar episode picker. Empty for movies/single-episode; TransportBar hides button at count <= 1.
    var seasonEpisodes: [JellyfinItem] = []

    /// Source-container chapters from `item.chapters`, sorted by start position so the scrub-bar
    /// and dropdown iterate in playback order. TransportBar hides the button at count <= 1.
    var chapters: [ChapterInfo] = []

    /// Original unsorted `item.chapters` index per sorted `chapters` entry (parallel array). The
    /// server's chapter-image endpoint keys on the unsorted container position, so the sort above
    /// would fetch the wrong image without this remap.
    @ObservationIgnored private var chapterImageIndices: [Int] = []

    /// Session-local picture-fill mode, seeded from `PlaybackPreferences.pictureMode` at startPlayback.
    /// Transient override, not persisted; settings owns the global default.
    var pictureMode: PlaybackPreferences.PictureMode = .original

    var videoFormat: VideoFormat = .sdr

    // MARK: - Shuffle / play queue

    /// When non-empty, playback advances through this shuffled list instead of the series
    /// successor; current item is `playQueue[queueIndex]`. Reuses the next-episode reload-in-place
    /// path to keep the engine AVPlayer alive across items (issue #15).
    var playQueue: [JellyfinItem] = []
    /// Index of the current item in `playQueue` (launch item = 0; `playNextEpisode()` increments).
    var queueIndex: Int = 0

    var isQueuePlayback: Bool { !playQueue.isEmpty }

    var nextEpisode: JellyfinItem?
    var showNextEpisodeOverlay = false
    var nextEpisodeCountdown = 10
    /// What the countdown started FROM, so the ring can draw a fraction. Not the fixed default: the
    /// user sets the length (Sodalite#67) and the no-outro fallback passes the real remaining
    /// seconds, and both have to drain one full turn of the ring.
    var nextEpisodeCountdownTotal = 10
    /// Fired once at demux EOF when there's no next episode; PlayerHostController routes it to the
    /// Menu dismiss path. Without it the player sits on a black frame with no focus target.
    var onPlaybackReachedEnd: (() -> Void)?

    // MARK: - Picture in Picture (tvOS)

    /// Native backend bound and PiP supported on this device; host writes it from the player bind.
    var isPiPAvailable = false
    /// AVKit's isPictureInPicturePossible; drives the transport button's enabled/dimmed state.
    var isPiPPossible = false
    /// Host hook: the AVPictureInPictureController lives host-side (PlayerPiPController).
    var onPiPStartRequested: (() -> Void)?
    /// Host hook (tvOS): content ended while the video lives in the PiP window; the coordinator closes
    /// the window and ends the session (auto-advance is disabled in PiP, see startNextEpisodeCountdown).
    var onPiPContentEnded: (() -> Void)?

    /// PiP advance capability by backend: native everywhere (5.12.0 in-place item handover); software
    /// only on iOS (Phase B contentSource swap; tvOS has no SW-PiP window, FB9751461).
    var pipCanAdvanceCurrentBackend: Bool {
        if player.playbackBackend == .native { return true }
        #if os(iOS)
        return player.playbackBackend == .software
        #else
        return false
        #endif
    }

    func requestPictureInPicture() {
        guard isPiPAvailable, isPiPPossible else { return }
        hideControls()
        onPiPStartRequested?()
    }

    var isCountdownActive = false
    var nextEpisodeTimer: Task<Void, Never>?
    var hasFetchedNextEpisode = false
    /// Successor rejected: the card was dismissed while the engine already sat in the terminal `.ended`
    /// state, where seek and play are no-ops. Routes end-of-media like end-of-content.
    var nextEpisodeCancelled = false
    /// Card dismissed while the source still runs. Scoped to one pass through the end window like
    /// `nextEpisodeCancelled`, but it only hides the card: the episode plays out and the advance still
    /// happens at the end (Sodalite#67, both used to be the same flag).
    var nextEpisodeOverlayDismissed = false

    /// Last `currentTime` seen by the next-episode hook, used to detect backward scrubs so the
    /// overlay resets; without it the show-logic is one-way and the overlay sticks on screen.
    var lastPlaybackTimeForNextEpisode: Double = 0

    /// Whole source-second last written to the `currentTime`/`remainingTime` labels. The clock ticks
    /// at 10 Hz but the labels are second-resolution, so we only re-format/re-publish when the second
    /// changes, cutting ~9/10 redundant string allocations and label invalidations per second.
    @ObservationIgnored private var lastDisplayedSecond: Int = -1

    // Intro + outro + recap markers, all from Jellyfin Media Segments / intro-skipper plugin in one call.
    var introSegment: MediaSegment?
    var outroSegment: MediaSegment?
    var recapSegment: MediaSegment?
    /// The segment the player currently offers to skip (intro or recap), nil when there is nothing to
    /// skip. Shows the skip pill even when controls are closed, and carries the seek target.
    var activeSkipSegment: ActiveSkipSegment?
    /// Set once per episode after auto-skip fires; keeps the time subscriber from re-triggering before
    /// the seek moves currentTime past the segment end. One latch per kind: a shared one would let the
    /// intro's auto-skip swallow a recap that follows it in the same episode.
    var didAutoSkipCurrentIntro: Bool = false
    var didAutoSkipCurrentRecap: Bool = false
    /// Outro equivalent; prevents repeat auto-skip while currentTime ticks toward outro.endSeconds.
    var didAutoSkipCurrentOutro: Bool = false
    /// Skip-lockout latch: while it names a kind, `updateSkipSegmentVisibility` refuses to re-offer that
    /// kind, so stale pre-seek ticks (between the flag flip and the seek landing) can't revive the pill
    /// mid-fade. A different kind resolves immediately, which is what chains a recap into the intro
    /// behind it. Cleared 500ms after `player.seek` returns (absorbs post-seek jitter) and on episode change.
    var didSkipCurrentSegment: SkipSegmentKind?

    // MARK: - Dependencies

    var item: JellyfinItem
    let player: AetherEngine

    /// Coded video dims for the overlay's bitmap-canvas mapping (.zero before load).
    var videoSize: CGSize {
        CGSize(width: Int(player.sourceVideoWidth), height: Int(player.sourceVideoHeight))
    }

    let playbackService: JellyfinPlaybackServiceProtocol
    /// Only the replaced-item lookup needs it, and only for movies (an episode resolves through the
    /// playback service's own season query). Nil where no caller passes one: live, previews.
    let itemService: JellyfinItemServiceProtocol?
    let userID: String
    var startFromBeginning: Bool
    /// Detail-screen prefetch, saving the first round trip. Bound to the id it was fetched for and
    /// consumed only through `matching(item.id)`: the response supplies `MediaSourceId` while the
    /// path carries `item.id`, and Jellyfin answers a crossed pair HTTP 400 (Sodalite#71).
    var cachedPlaybackInfo: PrefetchedPlaybackInfo?
    let preferences: PlaybackPreferences
    /// Sodalite#46 per-title memory; nil in contexts that do not persist picks (live, previews).
    let trackMemory: TrackSelectionMemory?

    /// Sodalite#50. A snapshot taken at construction: neither player surface offers a reveal, so it
    /// never needs to change mid-session. Nothing under Player/ reads the SwiftUI environment.
    let spoilerPolicy: SpoilerPolicy

    /// When set, `startPlayback()` selects the matching PlaybackInfo source instead of first.
    /// Nil keeps default-first. Set by the detail-view version picker.
    let preferredMediaSourceID: String?

    /// Scrub-preview thumbnail provider over the session FrameExtractor; configured in startPlayback,
    /// reset in stopPlayback.
    let scrubPreview: ScrubPreviewProvider

    // MARK: - Source outage

    /// Asks the Jellyfin server whether it is still there while the reader is stalled, and calls a
    /// terminal error when it is not. See `SourceOutageWatchdog` for why the host answers this and the
    /// engine cannot.
    @ObservationIgnored private var outageWatchdog: SourceOutageWatchdog?
    /// Latched by the watchdog's verdict. Read by the live recovery paths: retuning a channel on a server
    /// that does not answer only burns tuners.
    @ObservationIgnored private(set) var serverConfirmedUnreachable = false
    /// Position the outage interrupted, so "Try again" resumes there instead of at the item's last
    /// server-side progress report (which is up to 10s stale, and a dead server never received the last one).
    @ObservationIgnored private var outageResumeSeconds: Double?
    /// Set by a retry; overrides the resume position `startPlayback()` would take from `item.userData`.
    @ObservationIgnored private var resumeOverrideSeconds: Double?
    /// Stall time before the connection chip appears. Long enough that an ordinary segment-boundary
    /// hiccup never shows it.
    @ObservationIgnored static let connectionNoticeDelay: Double = 2
    @ObservationIgnored private var connectionNoticeTask: Task<Void, Never>?

    /// Session-scoped frame extractor (static stream URL); built in startPlayback, shut down in
    /// stopPlayback. Shared by `scrubPreview` and `chapterThumbnail(forIndex:)`.
    @ObservationIgnored private var frameExtractor: FrameExtractor?

    /// A chapter still. Prefers the Jellyfin-rendered chapter image (when `imageTag` is set, post
    /// "Chapter image extraction" task): pre-rendered, cheap, reliable. Falls back to decoding the
    /// still ourselves, which needs a deep random-access seek that flakes deeper into the file
    /// (root of issue #21). Nil if neither yields an image or index is invalid.
    func chapterThumbnail(forIndex index: Int) async -> CGImage? {
        guard chapters.indices.contains(index) else { return nil }
        let chapter = chapters[index]
        if let tag = chapter.imageTag, !tag.isEmpty,
           let url = playbackService.buildChapterImageURL(
               itemID: item.id,
               chapterIndex: chapterImageIndices[index],
               imageTag: tag,
               maxWidth: 320
           ),
           let image = await Self.loadServerChapterImage(from: url) {
            return image
        }
        guard let frameExtractor else { return nil }
        return await frameExtractor.thumbnail(at: chapter.startSeconds, maxWidth: 320)
    }

    /// Fetches + decodes a server chapter image via the shared `ImageCache` (memory-only). Auth rides
    /// the URL's `api_key` query so no header needed; `nonisolated static` runs the decode off MainActor.
    nonisolated private static func loadServerChapterImage(from url: URL) async -> CGImage? {
        if let cached = ImageCache.shared.image(for: url) { return cached.cgImage }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            let prepared = image.preparingForDisplay() ?? image
            ImageCache.shared.store(prepared, for: url)
            return prepared.cgImage
        } catch {
            return nil
        }
    }

    /// Fetch a trickplay tile sprite (cached whole, keyed by tile URL) and crop `crop` out of it.
    /// Off-MainActor (network + decode), mirroring loadServerChapterImage. The MainActor caller
    /// resolves the tile URL + crop rect from the TrickplayTileSet first. Nil on fetch failure or
    /// an out-of-bounds crop.
    nonisolated private static func fetchTrickplayCrop(from url: URL, crop: CGRect) async -> CGImage? {
        let tileImage: UIImage
        if let cached = ImageCache.shared.image(for: url) {
            tileImage = cached
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let image = UIImage(data: data) else { return nil }
                let prepared = image.preparingForDisplay() ?? image
                ImageCache.shared.store(prepared, for: url)
                tileImage = prepared
            } catch {
                return nil
            }
        }
        guard let cg = tileImage.cgImage else { return nil }
        guard crop.maxX <= CGFloat(cg.width), crop.maxY <= CGFloat(cg.height),
              let cropped = cg.cropping(to: crop) else { return nil }
        return cropped
    }

    /// Use server trickplay only when the user opted in AND the item actually has tiles.
    nonisolated static func shouldUseServerTrickplay(preferServer: Bool, tileSet: TrickplayTileSet?) -> Bool {
        preferServer && tileSet != nil
    }

    /// Open-time routing-probe budget for the engine on remote direct-play / direct-stream sources (#68).
    /// Direct play and direct stream serve the original container, whose sparse HDMV PGS tracks and cover-art
    /// attachments otherwise drag the engine's `find_stream_info` to the full 50 MB / 60 s default, adding
    /// ~13-14 s before first frame over a slow connection. Video and HDR/DV signaling resolve from the first
    /// packets and every audio track interleaves early, so a 16 MB / 10 s cap keeps the audio picker complete
    /// (it reads `player.audioTracks`, which comes from this probe) while skipping the PGS tail. The subtitle
    /// picker is built from Jellyfin `MediaStreams`, and bitmap tracks select through the engine's own
    /// full-budget side-demuxer by absolute container index, so a routing probe that skips a PGS track loses
    /// nothing. Transcode sessions get a clean HLS stream with no sparse-track tail, so they keep the default.
    nonisolated static func remoteDirectPlayProbeBudget(method: PlayMethod, source: PlaybackMediaSource) -> (probesize: Int64?, maxAnalyzeDuration: Int64?) {
        switch method {
        case .transcode:
            return (nil, nil)
        case .directPlay, .directStream:
            // Live / infinite / external-URL sources (e.g. a remote .strm IPTV stream) have no fixed size and a
            // continuous, often Range-ignoring body; the sparse-tail cap starves find_stream_info and the source
            // fails or crashes the engine probe (issue #31). Only cap sized server-file remuxes (the sparse
            // PGS / cover-art tail case the cap was added for).
            let isStreaming = source.size == nil || (source.path?.hasPrefix("http") ?? false)
            return isStreaming ? (nil, nil) : (16 * 1024 * 1024, 10 * 1_000_000)
        }
    }

    // MARK: - Internal State

    var cancellables = Set<AnyCancellable>()
    var progressTimer: Task<Void, Never>?
    var progressReportOnDemandTask: Task<Void, Never>?
    var controlsTimer: Task<Void, Never>?
    /// In-flight continuous (hold-to-seek) scrub task; non-nil while left/right is held, advances
    /// scrubProgress with acceleration until release (see PlayerViewModel+Scrubbing).
    var continuousSeekTask: Task<Void, Never>?
    /// In-flight initial-launch task (see `beginPlayback`), held so a back-press during the spinner
    /// can cancel it before `player.load()`; untracked it would resume after stopPlayback's
    /// player.stop() and restart playback behind a dismissed player (audio runs until app restart).
    var loadTask: Task<Void, Never>?
    /// Late fetch of the `detailFields` a slim launch item arrived without (Sodalite#94).
    @ObservationIgnored private var detailEnrichmentTask: Task<Void, Never>?
    /// Latched by `stopPlayback()`; startPlayback resets it at entry and re-checks after every await
    /// so a teardown racing an in-flight load (incl. next-episode / season-picker tasks, not loadTask
    /// and thus uncancellable) still bails before or stops right after `player.load()`.
    var isTearingDown = false
    var hasReportedStart = false
    var hasStartedPlaying = false
    /// Resume position, used as minimum for progress reports so Jellyfin doesn't reset progress on early stop.
    var resumePositionTicks: Int64 = 0
    var mediaSourceID: String = ""
    /// The `MediaSource` this session is actually playing, exactly as PlaybackInfo returned it. The launch
    /// item is not a reliable description of it: episode rows arrive from a slim list query that carries no
    /// `MediaSources` and no `MediaStreams` at all (movies come from a detail fetch that does), so anything
    /// reading container metadata off `item` shows a full readout for a film and a half-empty one for an
    /// episode of the same library. Nil only on the remembered-URL live shortcut, which reaches the tuner
    /// without asking Jellyfin anything, and where the engine's own published source identity answers instead.
    var activePlaybackSource: PlaybackMediaSource?
    var playSessionID: String?
    var activePlayMethod: PlayMethod = .directPlay
    var subtitleStreams: [MediaStream] = []
    /// Lowercased Jellyfin codec of the active subtitle ("ass"/"ssa"/"subrip"/...), nil when off.
    /// The overlay reads it to gate the raw-ASS-event-line stripper.
    var activeSubtitleCodec: String?
    /// Disc parity: forced captions render even while the user's subtitles are OFF. The engine
    /// silently decodes a forced source (`activeSubtitleIndex` stays nil, picker shows "Off"); the
    /// cue mirror filters to `isForced` when the source is a full bitmap track (AE#146). Resolved
    /// by `applyForcedSubtitleFallback`, decisions in `ForcedSubtitleFallback`.
    var forcedSubtitleFallback: ForcedSubtitleFallback.Mode = .none
    /// Styled ASS rendering bridge, active only while the selected embedded track is ASS/SSA
    /// (AetherEngine#30). Lazy to capture `player`; @ObservationIgnored, observable surface is `assRenderer`.
    @ObservationIgnored private lazy var assCoordinator = ASSRenderCoordinator(player: player)
    /// Observable mirror of `assCoordinator.renderer` (coordinator isn't @Observable), updated at
    /// every activate/deactivate so the overlay swaps between styled ASS and cue path reactively.
    private(set) var assRenderer: AssSubtitlesRenderer?
    /// One-shot observation of `engine.sidecarASSHeader` for styled ASS on EXTERNAL .ass/.ssa sidecars
    /// (AetherEngine#48): sidecar headers publish asynchronously (unlike embedded TrackInfo), so
    /// activation waits for the first non-nil value. Cancelled on track change / deactivate.
    @ObservationIgnored private var sidecarASSHeaderCancellable: AnyCancellable?
    /// In-flight transcode-path SRT load (server extraction can take up to 120s). Cancelled when the
    /// user switches or disables the subtitle track so a stale load can't clobber the new selection.
    @ObservationIgnored private var subtitleLoadTask: Task<Void, Never>?

    /// Live only: the automatic subtitle pick runs once per session, when the engine's track list
    /// first arrives. A latch rather than a time guard, so a republished list cannot override a pick
    /// the user has made since.
    @ObservationIgnored private var didAutoSelectLiveSubtitle = false
    /// Index signature of the last engine track list taken over on live. nil until the first publish
    /// of a session, so an empty first list still counts as a change and gets logged: a channel that
    /// carries no subtitle stream must not look like a sink that never fired.
    @ObservationIgnored private var lastLiveSubtitleIndices: [Int]?

    /// Arm the live subtitle sink for a session that is about to load. Every live load goes through
    /// here, the first one and every re-tune (#64), because a stale latch would make the sink treat
    /// the new session's track list as one it has already handled and skip the automatic pick.
    func resetLiveSubtitleAutoSelect() {
        didAutoSelectLiveSubtitle = false
        lastLiveSubtitleIndices = nil
        subtitleStreams = []
    }

    /// Sodalite#63: playhead before the current burst of backward jumps, recorded on press and consumed
    /// by the commit. Nil means the next commit is not a skip back (a pan, a hold-seek, a forward jump).
    /// Internal, not private: the scrub commits live in extensions in other files.
    @ObservationIgnored var pendingSkipBackOrigin: Double?
    /// The open skip-back window: the track it switched on and the position that ends it.
    @ObservationIgnored var skipBackSubtitleWindow: SkipBackSubtitleWindow.State?
    /// Sodalite#65: where the current burst of backward jumps started. Unlike `pendingSkipBackOrigin`
    /// it survives the commits inside the burst, so every press measures its distance against the
    /// place the user actually left; a pause longer than `SkipBackSubtitleWindow.burstGap`, a forward
    /// jump or any other commit starts over.
    @ObservationIgnored var skipBackBurstOrigin: Double?

    /// Sodalite#65: the open muted-playback window, opened by the system's own caption request and
    /// closed when the output is audible again.
    @ObservationIgnored var systemCaptionWindow: SystemCaptionWindow.State?
    /// When the last backward jump was committed, so a caption request the system made because of
    /// that jump is not mistaken for the muted-playback trigger.
    @ObservationIgnored var lastBackwardJumpAt: Date?
    /// A system caption request this long after a backward jump belongs to the jump. Generous
    /// against the seek and the system's own reaction time; the mute trigger is a separate user
    /// action and is never this close to one.
    static let systemCaptionSkipBackGrace: TimeInterval = 3

    /// AE#88: Jellyfin stream index -> engine external track id, rebuilt per load; late downloads
    /// register lazily on first select.
    @ObservationIgnored var externalEngineTrackIDs: [Int: Int] = [:]
    /// Coordinator reload pre-announcements; the overlay's frame view subscribes so reload-induced
    /// transient nil frames never blank a visible subtitle. Stable for the VM lifetime.
    var assReloadSignal: PassthroughSubject<Void, Never> { assCoordinator.reloadSignal }

    // MARK: - Live TV

    /// True for a live channel (not VOD); gates DVR transport, disables resume / chapters / next-episode.
    private(set) var isLiveSession = false
    /// Jellyfin tuner handle for the current live stream; captured on load, released on teardown. Nil for VOD.
    var activeLiveStreamID: String?
    /// Live-edge mirror fields, populated by PlayerViewModel+Live from the engine's live surfaces.
    var liveSeekableRange: ClosedRange<Double>?
    var isAtLiveEdge: Bool = true
    var behindLiveSeconds: Double = 0
    /// Channel for live sessions. Nil for VOD.
    let liveChannel: JellyfinChannel?
    /// What is on air right now, as far as this session knows. Seeded with the programme that was on
    /// at tune time and kept current by `startFollowingLiveProgram` (#96), because `item` is built
    /// from it and the title above the picture reads `item`.
    var liveProgram: JellyfinProgram?
    /// Wakes at the programme's end and asks what took its place. Nil for VOD.
    var liveProgramFollow: Task<Void, Never>?
    /// Live-TV service for tuner lifecycle (PlayerViewModel+Live). Nil for VOD.
    let liveTvService: JellyfinLiveTvServiceProtocol?
    /// Latched by `observeLiveEdge()` so a retune (re-runs `loadLiveStream`) can't stack duplicate sinks.
    var hasLiveEdgeObservers = false
    /// Retune guard for `handleLiveSourceReset`: in-flight retune swallows further resets; per-session
    /// cap + min spacing stops a server replaying on EVERY reconnect from looping retunes forever.
    var liveRetuneInFlight = false
    var lastLiveRetuneAt: Date?
    var liveRetuneCount = 0
    /// When live first reached .playing; gates startup-window spinner masking (cold transcodes stall
    /// once right after start while the server catches up to real time).
    var liveFirstPlayingAt: Date?
    /// True while this live session plays the tuner upstream directly (HLS ingest), Jellyfin out of the path.
    var usedDirectLivePath = false
    /// Latch: the once-per-session direct-to-Jellyfin fallback has been consumed.
    var didAttemptLiveFallback = false
    /// True while this live session reads the tuner's own buffered stream (`/LiveTv/LiveStreamFiles/...`)
    /// rather than the static route, keeping Jellyfin's redundant copy-remux out of the path (#70).
    var usedLiveTunerFilePath = false
    /// Latch: the once-per-session retreat from the tuner-file route to the static route is consumed.
    var didAbandonLiveTunerFile = false
    /// Remembered upstream URLs, so a repeat tune of a direct channel skips Jellyfin entirely. Nil for VOD.
    let directStreamMemory: LiveDirectStreamMemory?
    /// Which of the four live routes carried this tune, nil for VOD and until one is chosen. It mirrors the
    /// `[LiveDirect] route=` line, which lives in a ring buffer only a diagnostic build's in-player HUD can
    /// render; a reporter cannot reach it. In the stats panel the same fact is a screenshot (Sodalite#70,
    /// where the route was the missing witness for a whole round of testing).
    var liveRoute: LiveRoute?
    /// The audio stream the viewer picked on this live channel (#64), named at load on every
    /// subsequent tune of the session. It outlives the switch on purpose: a recovery retune re-runs
    /// the same load, and dropping it there would silently put the channel back on its default track.
    var pendingLiveAudioStreamIndex: Int?

    init(
        item: JellyfinItem,
        startFromBeginning: Bool,
        playbackService: JellyfinPlaybackServiceProtocol,
        userID: String,
        preferences: PlaybackPreferences,
        itemService: JellyfinItemServiceProtocol? = nil,
        trackMemory: TrackSelectionMemory? = nil,
        spoilerPolicy: SpoilerPolicy = .disabled,
        cachedPlaybackInfo: PrefetchedPlaybackInfo? = nil,
        preferredMediaSourceID: String? = nil,
        playQueue: [JellyfinItem] = [],
        isLiveSession: Bool = false,
        liveChannel: JellyfinChannel? = nil,
        liveProgram: JellyfinProgram? = nil,
        liveTvService: JellyfinLiveTvServiceProtocol? = nil,
        directStreamMemory: LiveDirectStreamMemory? = nil
    ) {
        self.item = item
        self.player = DependencyContainer.playerEngine
        self.startFromBeginning = startFromBeginning
        self.playbackService = playbackService
        self.userID = userID
        self.preferences = preferences
        self.itemService = itemService
        self.trackMemory = trackMemory
        self.spoilerPolicy = spoilerPolicy
        self.scrubPreview = ScrubPreviewProvider()
        self.cachedPlaybackInfo = cachedPlaybackInfo
        self.preferredMediaSourceID = preferredMediaSourceID
        self.playQueue = playQueue
        self.queueIndex = 0
        self.isLiveSession = isLiveSession
        self.liveChannel = liveChannel
        self.liveProgram = liveProgram
        self.liveTvService = liveTvService
        self.directStreamMemory = directStreamMemory
    }

    // MARK: - Lifecycle

    /// Initial-launch entry point (host VC, modal appear), via a tracked task so a back-press during
    /// the spinner cancels the in-flight startPlayback (engine throws CancellationError out of
    /// player.load()) before it touches the shared engine.
    func beginPlayback() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.startPlayback() }
    }

    /// Chapters sorted by start position, each entry paired with its index in the server's original
    /// array (chapter image URLs address that array, not the sorted one). The API documents
    /// start-position order but some legacy taggers emit out of sequence.
    static func orderedChapters(from chapters: [ChapterInfo]?) -> (chapters: [ChapterInfo], imageIndices: [Int]) {
        let ordered = (chapters ?? [])
            .enumerated()
            .sorted { $0.element.startPositionTicks < $1.element.startPositionTicks }
        return (ordered.map(\.element), ordered.map(\.offset))
    }

    /// Single owner for the chapter arrays: the load reads them off the launch item, a late detail
    /// fetch re-reads them off the enriched one, and both land here.
    private func applyChapterOrdering() {
        let ordered = Self.orderedChapters(from: item.chapters)
        chapters = ordered.chapters
        chapterImageIndices = ordered.imageIndices
    }

    /// Whether the item still owes us the fields only `detailFields` requests.
    ///
    /// Chapters and the trickplay manifest ride on the item, and every route that starts an episode
    /// (the series Play button, an episode row, an auto-advance, the in-player season picker) hands
    /// over a list item fetched with `episodeListFields` or `homeRowFields`, neither of which names
    /// them. Movies looked immune only because their detail screen plays the item it fetched itself.
    ///
    /// `nil` is "never requested" and `[]` is the server answering "this file has none", so keeping
    /// them apart spares a chapterless file a round-trip on every launch (Sodalite#94).
    static func needsDetailEnrichment(item: JellyfinItem, isLive: Bool) -> Bool {
        // A live item is synthesised from the channel plus its EPG program; there is no library item
        // behind it, and the live load path shows no chapter UI at all.
        guard !isLive else { return false }
        return item.chapters == nil
    }

    /// Fetch the fields the caller did not ask for, rather than requiring every call site to hand over
    /// a fat item. Deliberately not awaited by the load: the chapter button, the scrub-bar ticks and
    /// the preview are all reactive, and blocking here would make the prefetched-PlaybackInfo route
    /// (Sodalite#71) trade its saved round-trip back for this one before the first frame.
    private func startDetailEnrichment() {
        detailEnrichmentTask?.cancel()
        detailEnrichmentTask = nil
        guard Self.needsDetailEnrichment(item: item, isLive: isLiveSession),
              let itemService else { return }
        let itemID = item.id
        detailEnrichmentTask = Task { [weak self] in
            guard let self,
                  let detail = try? await itemService.getItemDetail(userID: self.userID, itemID: itemID)
            else { return }
            // An auto-advance can swap the item while this is in flight; the enriched twin of the
            // episode we just left has nothing to say about the one now playing.
            guard !Task.isCancelled, !self.isTearingDown, self.item.id == itemID else { return }
            self.applyEnrichedDetail(detail)
        }
    }

    private func applyEnrichedDetail(_ detail: JellyfinItem) {
        let hadTrickplay = item.trickplay != nil
        item.applyDetailFields(from: detail)
        applyChapterOrdering()
        // The preview was wired to the local extractor because the launch item carried no manifest;
        // rewire it now the tiles are known instead of leaving the session on the expensive path.
        if !hadTrickplay, item.trickplay != nil, let source = activePlaybackSource {
            configureScrubPreview(source: source)
        }
    }

    /// Server trickplay tiles when the item carries a manifest, the local extractor / cache stills
    /// otherwise. One owner, because a late detail fetch has to be able to re-run the same decision.
    private func configureScrubPreview(source: PlaybackMediaSource) {
        let trickplayTileSet = TrickplayTileSet(
            trickplay: item.trickplay, mediaSourceID: source.id, targetWidth: 320)
        if Self.shouldUseServerTrickplay(
            preferServer: preferences.preferServerTrickplay, tileSet: trickplayTileSet),
           let tileSet = trickplayTileSet {
            let itemID = item.id
            let service = playbackService
            scrubPreview.configure(
                serverThumbnail: { seconds in
                    // MainActor: resolve tile index + crop, then hop off-actor to fetch/decode.
                    guard let placement = tileSet.tile(forSeconds: seconds),
                          let url = service.buildTrickplayTileURL(
                              itemID: itemID, width: tileSet.width, tileIndex: placement.tileIndex)
                    else { return nil }
                    return await Self.fetchTrickplayCrop(from: url, crop: placement.crop)
                },
                enabled: preferences.showScrubPreview
            )
        } else {
            // Cache-first: resident loopback segments decode with no second connection;
            // the extractor is the fallback for non-resident positions. supportsCacheBackedStills
            // is false on the software-decode path (no HLSVideoEngine) so it degrades to the
            // extractor. Disc titles keep the extractor: scrubThumbnail wants playlist/output
            // seconds while our value is the display axis, and a disc shift would return a wrong
            // (not nil) frame; the extractor is correct by construction there.
            let engine = player
            let cacheThumbnail: (Double, Int) async -> CGImage? = { [weak engine] seconds, maxWidth in
                guard let engine, engine.supportsCacheBackedStills, engine.discTitles.isEmpty else {
                    return nil
                }
                return await engine.scrubThumbnail(atSeconds: seconds, maxWidth: maxWidth)
            }
            scrubPreview.configure(
                extractor: frameExtractor,
                cacheThumbnail: cacheThumbnail,
                enabled: preferences.showScrubPreview
            )
        }
    }

    func startPlayback() async {
        isTearingDown = false
        hostLoadActive = true
        clearError()
        // Cleared before the load, not after it: an auto-advance swaps `item` first, and a source left
        // standing from the previous episode would describe the new one until PlaybackInfo answers.
        activePlaybackSource = nil
        liveRoute = nil
        applyChapterOrdering()
        startDetailEnrichment()
        // Reset to the global default each session so in-player overrides don't bleed across episodes/movies.
        pictureMode = preferences.pictureMode
        applyPictureMode()
        #if DEBUG
        print("[PlayerVM] startPlayback: item=\(item.name), seriesId=\(item.seriesId ?? "nil"), type=\(item.type), chapters=\(chapters.count)")
        #endif

        // Now Playing is driven by AVKit's internal session (auto-activates with showsPlaybackControls
        // + an assigned AVPlayer, reads AVPlayerItem.externalMetadata).

        do {
            // Live channels take a dedicated load path (open tuner, infinite live MediaSource, isLive
            // + DVR window). VOD wiring below (resume, chapters, intro markers, episode picker) doesn't
            // apply; the shared post-load steps are duplicated here on purpose to keep the VOD path untouched.
            if isLiveSession {
                stageInitialNowPlayingMetadata()
                usedDirectLivePath = false
                didAttemptLiveFallback = false
                usedLiveTunerFilePath = false
                didAbandonLiveTunerFile = false
                try await loadLiveStream()
                if Task.isCancelled || isTearingDown {
                    player.stop()
                    // loadLiveStream() may have opened a tuner before cancel landed; release so server doesn't leak.
                    releaseLiveTunerIfNeeded()
                    hostLoadActive = false
                    return
                }
                // The engine picked the preferred-language audio on the first frame (#72), so there is
                // no live selectAudioTrack reload here (it used to misfire on single-track channels:
                // Das Erste, frozen frame).
                // The subtitle pick is NOT made here: live has no stream list yet at this point, so
                // the call that used to sit here resolved over an empty array and did nothing. The
                // $subtitleTracks sink in startObserving owns it, and re-arms per channel.
                resetLiveSubtitleAutoSelect()
                resetTemporarySubtitleWindows()
                startFollowingLiveProgram()
                hostLoadActive = false
                isPlaying = true
                startObserving()
                Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
                await reportStart()
                startProgressReporting()
                return
            }

            let info: PlaybackInfoResponse
            // Only a prefetch that names THIS item: the play target can move between the prefetch and
            // the launch (Next Up rolling forward as the player exits, an auto-advance, a replaced item),
            // and a response from the previous target would put its source id in MediaSourceId under this
            // item's path, which Jellyfin refuses with HTTP 400.
            if let cached = cachedPlaybackInfo?.matching(item.id), !cached.mediaSources.isEmpty {
                info = cached
            } else {
                info = try await playbackService.getPlaybackInfo(
                    itemID: item.id,
                    userID: userID,
                    profile: DirectPlayProfile.current()
                )
            }
            playSessionID = info.playSessionId

            let source = info.mediaSources.first(where: { $0.id == preferredMediaSourceID })
                ?? info.mediaSources.first
            guard let source else {
                throw PlayerEngineError.noSource
            }
            mediaSourceID = source.id
            activePlaybackSource = source

            #if DEBUG
            print("[PlayerViewModel] Source: container=\(source.container ?? "nil"), directPlay=\(source.supportsDirectPlay ?? false), directStream=\(source.supportsDirectStream ?? false), transcoding=\(source.supportsTranscoding ?? false)")
            if let tURL = source.transcodingUrl {
                print("[PlayerViewModel] TranscodingURL: \(tURL.prefix(120))...")
            }
            #endif

            // Keep all subtitle tracks: bitmap codecs (PGS/HDMV/DVB/DVD) now render as CGImage so they
            // belong in the picker, and forced tracks stay (many releases mark every track forced). Dedupe
            // keys on forced/signs/sdh descriptors so distinct same-language tracks don't collapse.
            subtitleStreams = Self.dedupedSubtitleStreams(from: source.mediaStreams)

            let url: URL
            if source.supportsDirectPlay == true || source.supportsDirectStream == true {
                let isDirectPlay = source.supportsDirectPlay == true
                guard let directURL = playbackService.buildStreamURL(
                    itemID: item.id,
                    mediaSourceID: source.id,
                    container: source.container,
                    isStatic: isDirectPlay
                ) else {
                    throw PlayerEngineError.noURL
                }
                url = directURL
                activePlayMethod = isDirectPlay ? .directPlay : .directStream
                #if DEBUG
                print("[PlayerViewModel] Using direct \(isDirectPlay ? "play" : "stream")")
                #endif
            } else if let transcodePath = source.transcodingUrl, !transcodePath.isEmpty {
                guard let transcodeURL = playbackService.buildTranscodeURL(relativePath: transcodePath) else {
                    throw PlayerEngineError.noURL
                }
                url = transcodeURL
                activePlayMethod = .transcode
                #if DEBUG
                print("[PlayerViewModel] Using transcoded stream")
                #endif
            } else {
                throw PlayerEngineError.noURL
            }

            // Scrub preview + chapter thumbnails decode stills from the original file (isStatic:true)
            // regardless of playback method, so transcode sessions still get a preview.
            if let previewURL = playbackService.buildStreamURL(
                itemID: item.id, mediaSourceID: source.id,
                container: source.container, isStatic: true
            ) {
                // Session-coupled: elective thumbnail decodes yield while the engine's playback
                // pipeline is starved (startup, restarts), instead of competing for the link.
                frameExtractor = player.makeFrameExtractor(url: previewURL)
            } else {
                frameExtractor = nil
            }
            configureScrubPreview(source: source)

            let startPos: Double?
            // A retry after a source outage resumes where the outage hit: the item's server-side progress
            // is up to a reporting interval stale, and the report that would have fixed that is exactly the
            // one the dead server never received.
            if let override = resumeOverrideSeconds, override > 0 {
                startPos = override
                resumePositionTicks = Int64(override * 10_000_000)
                resumeOverrideSeconds = nil
            } else if !startFromBeginning,
               let ticks = item.userData?.playbackPositionTicks, ticks > 0 {
                startPos = ticks.ticksToSeconds
                resumePositionTicks = ticks
            } else {
                startPos = nil
                resumePositionTicks = 0
            }

            // Stage title/description as externalMetadata BEFORE engine.load (applied pre-replaceCurrentItem);
            // cover follows async post-load via refreshExternalMetadataWithArtwork(); AVKit re-reads it.
            stageInitialNowPlayingMetadata()

            // Bail before touching the shared engine if torn down while awaiting playback info, else
            // this in-flight task calls player.load() AFTER stopPlayback's player.stop() and restarts
            // playback with no UI to dismiss it (audio runs until app restart).
            if Task.isCancelled || isTearingDown {
                hostLoadActive = false
                return
            }

            // Single load path: engine picks native AVPlayer or its sample-buffer fallback (VP9/AV1,
            // DV P7). Format detection, HDMI HDR handshake, layer ownership, refresh-rate matching all
            // inside engine.load now.
            LogTap.shared.note("[PlayerVM] engine.load url=\(url.absoluteString)")
            // The ENGINE is the sole criteria writer here: suppressDisplayCriteria false below,
            // appliesPreferredDisplayCriteriaAutomatically false on PlayerHostController. It writes the
            // criteria pre-flight, before the AVPlayerItem exists, which is the ordering DV P5 cold start
            // and the tvOS 26.5+ variant validator both need. The two flags must move together; see
            // PlayerHostController init for the full rationale.
            // matchContentEnabled (tvOS Match Content master toggle) feeds the engine's master-vs-media
            // playlist routing: panel-in-HDR makes master routing safe regardless of the match flag
            // (SUPPLEMENTAL-CODECS=dvh1 upgrade per AetherEngine#4), else HDR sources fall back to media
            // to avoid AVPlayer asset-open -11848 on an SDR panel. panelIsInHDRMode is the pre-load
            // snapshot the engine consults only on the suppressed path; ours reads live EDR headroom after
            // its own handshake instead, so we pass it for completeness, not because it is consumed.
            // Cap the engine's open-time probe on sized server-file direct-play/-stream remuxes so a sparse PGS
            // / cover-art tail doesn't drag find_stream_info to the 50 MB default before first frame (#68).
            // Live/infinite/external-URL sources (remote .strm IPTV) are exempt: the cap truncates their
            // continuous probe and crashes the load (#31). Safe: the subtitle picker selects via the engine's
            // full-budget side-demuxer.
            let probeBudget = Self.remoteDirectPlayProbeBudget(method: activePlayMethod, source: source)
            // Hand the language preference to the engine so it picks the audio track on the first frame
            // from its single probe (#72), instead of us reloading via selectAudioTrack after load.
            // A remembered pick (Sodalite#46) outranks the global preference here; only a different
            // track of the SAME language still needs the post-load reload in resolveInitialTracks.
            let rememberedAudioLanguage = memoryScopeKey
                .flatMap { trackMemory?.entry(for: $0) }?.audio?.language
            let preferredAudio = rememberedAudioLanguage ?? effectivePreferredAudioLanguage()
            // AE#88: declare external Jellyfin subs at load so they list in engine.subtitleTracks
            // and join the native WebVTT renditions (PiP / external display); the map routes UI selections to engine ids.
            let externalSubs = Self.externalSubtitleDescriptors(streams: subtitleStreams) { stream in
                playbackService.buildSubtitleURL(
                    itemID: item.id, mediaSourceID: mediaSourceID,
                    streamIndex: stream.index, format: stream.codec ?? "srt")
            }
            externalEngineTrackIDs = externalSubs.mapping
            try await player.load(
                url: url,
                startPosition: startPos,
                options: LoadOptions(
                    suppressDisplayCriteria: false,
                    forceDolbyVisionOnNonDVDisplay: preferences.forceDolbyVisionOnNonDVDisplay,
                    matchContentEnabled: Self.matchContentEnabled,
                    panelIsInHDRMode: Self.panelIsInHDRMode,
                    audioBridgeMode: preferences.audioBridgeMode,
                    // Raw ASS event lines for the styled path; only affects ASS/SSA cue content.
                    preserveASSMarkup: true,
                    // Sodalite#32 / #34: serve a WebVTT rendition with eager readers so a real legible track
                    // exists for the moments the video leaves the app's view hierarchy (PiP, AirPlay, wired
                    // external display), where the on-frame overlay can't draw. The engine marks the rendition
                    // matching nativeSubtitlePreferredLanguages DEFAULT=YES (required for a host-selected legible
                    // track to render) and exposes it as nativeSubtitleDefaultOrdinal.
                    prepareNativeSubtitles: Self.nativeSubtitleRenditionEnabled,
                    eagerNativeSubtitleReaders: Self.nativeSubtitleRenditionEnabled,
                    nativeSubtitlePreferredLanguages: Self.nativeSubtitleRenditionEnabled
                        ? (preferences.preferredSubtitleLanguage.map { [$0] } ?? [])
                        : [],
                    probesize: probeBudget.probesize,
                    maxAnalyzeDuration: probeBudget.maxAnalyzeDuration,
                    preferredAudioLanguages: preferredAudio.map { [$0] } ?? [],
                    externalSubtitles: externalSubs.descriptors,
                    forwardBufferSegments: preferences.networkBufferDepth.forwardBufferSegments
                )
            )

            // Teardown can land between load() returning and observation wiring (back-press just as the
            // asset opened); stop the engine we just started so nothing plays behind a dismissed player.
            if Task.isCancelled || isTearingDown {
                player.stop()
                hostLoadActive = false
                return
            }

            totalTime = formatSeconds(effectiveDuration)
            // The engine resolved the preferred-language audio on the first frame (#72), so there is no
            // selectAudioTrack reload here; read what it picked to drive the matching subtitle.
            let chosenAudio = player.audioTracks.first(where: { $0.id == player.activeAudioTrackIndex })
            // Fullscreen uses the custom on-frame overlay for subtitles (the user's pick). The native WebVTT
            // rendition is served but stays UNSELECTED here; it is selected only when the video leaves the app
            // (PiP / external display, #32 / #34), so the two never double up. Fullscreen behaviour is identical to main.
            resetNativeSubtitleRenderingState()
            resetTemporarySubtitleWindows()
            resolveInitialTracks(audioLanguage: chosenAudio?.language)
            applyForcedSubtitleFallback()

            hostLoadActive = false
            isPlaying = true

            startObserving()
            // Cover fetch is async post-load; engine writes externalMetadata to the live item and the session republishes.
            Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
            await reportStart()
            startProgressReporting()

            // Background fetch, doesn't block start; the next tick resolves the skip pill once the markers land.
            Task { [weak self] in await self?.loadEpisodeSegments() }

            // Powers the transport-bar episode picker; stays empty (picker hidden) for movies / single-episode.
            Task { [weak self] in await self?.loadSeasonEpisodes() }

        } catch is CancellationError {
            // Engine signals a SUPERSEDED load this way (newer load/stop took the singleton mid-flight,
            // rapid channel zap / dismiss during spin-up). The successor owns the engine + UI; an error
            // here would clobber it. Still release any tuner THIS load opened.
            releaseLiveTunerIfNeeded()
        } catch {
            // Release the tuner if a live load opened one before failing. No-op for VOD.
            releaseLiveTunerIfNeeded()
            // The engine classifies its own failures and assigns `errorInfo` before the state that carries
            // them, so a load that threw still has its classification sitting here. Read once: `load()`
            // clears it on the next attempt's `.loading`, so it can only ever describe THIS attempt.
            let engineInfo = player.errorInfo
            LogTap.shared.note(
                PlayerEngineErrorPresentation.logLine(for: engineInfo, engineMessage: error.localizedDescription)
            )
            if isLiveSession, case .liveAudioUnsupported = (error as? PlayerEngineError) {
                // Refused before the engine was asked, so there is no classification to read and
                // "the channel's source may be offline" would be a lie: it is on the air and we
                // cannot decode it (#100).
                setError(from: error)
            } else if isLiveSession && !(error is APIError) {
                // Engine-level live open failure (probe fail-fast): friendly message, APIErrors keep their trio.
                setLiveChannelUnavailableError(info: engineInfo)
            } else if ReplacedItemRecoveryTrigger.serverAnswered(hostError: error, engineError: engineInfo),
                      beginReplacedItemRecovery(
                        onGiveUp: { [weak self] in self?.setStartError(error, engineInfo: engineInfo) }) {
                // The server answered with a status, which a *arr upgrade earns whichever endpoint it hits.
                // The library is being asked whether this item still exists; the spinner stays up and the
                // recovery paints this error itself if nothing was replaced.
                return
            } else {
                setStartError(error, engineInfo: engineInfo)
            }
            hostLoadActive = false
        }
    }

    /// tvOS's single "Match Content" flag. It covers Match Dynamic Range AND Match Frame Rate with no
    /// way to tell them apart, which is exactly why it cannot answer whether the panel presents HDR
    /// (AE#459); it is passed to the engine as the criteria-matching input and nothing else.
    static var matchContentEnabled: Bool {
        #if os(tvOS)
        guard let win = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first
        else { return false }
        return win.avDisplayManager.isDisplayCriteriaMatchingEnabled
        #else
        return false
        #endif
    }

    /// Snapshot of whether the connected panel is currently presenting
    /// Whether the panel is presenting in HDR now (`UIScreen.currentEDRHeadroom` > 1.0). Feeds the
    /// engine's master-vs-media routing as the strong signal that master routing is safe even with
    /// Match Dynamic Range off (AetherEngine#4).
    static var panelIsInHDRMode: Bool {
        #if os(tvOS)
        guard let win = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first
        else { return false }
        // Headroom 1.0 = SDR, > 1.0 = HDR active; epsilon dodges a boundary float-comparison glitch.
        return win.screen.currentEDRHeadroom > 1.001
        #else
        return false
        #endif
    }

    /// Sodalite#32 / #34: gates serving the native WebVTT legible rendition. It exists so AVKit can
    /// render a real subtitle track itself whenever the video leaves the app's own view hierarchy (a PiP window,
    /// an AirPlay receiver, or a wired external display), where the host's on-frame overlay cannot draw. The
    /// engine serves DEFAULT=NO,AUTOSELECT=NO renditions with eager readers; the host selects one on those transitions and
    /// deselects it back in fullscreen, where the on-frame overlay owns subtitles. tvOS was overlay-only until
    /// tvOS PiP (2026-07-20); fullscreen stays overlay-owned on both platforms via the engine's #38
    /// deselect-at-load pin.
    static var nativeSubtitleRenditionEnabled: Bool { true }

    /// Tear down the session. Local work (progress reporting, KVO, engine stop) finishes inline;
    /// the network reportStop is detached so a slow Jellyfin server can't stall the dismiss path
    /// (default 30s timeout would leave the player up on a slow CDN, DrHurt #12). Session endpoints
    /// opt into a 90s timeout so the position write survives a slow origin.
    func stopPlayback() {
        // Latch teardown + cancel the in-flight launch (re-checked after every await in startPlayback;
        // cancel throws CancellationError out of player.load()) so a back-press-during-load can't resume
        // into player.load() after the player.stop() below.
        isTearingDown = true
        loadTask?.cancel()
        loadTask = nil
        stopProgressReporting()
        progressReportOnDemandTask?.cancel()
        progressReportOnDemandTask = nil
        // External dismissals (deep link / TopShelf) don't cancel the next-episode countdown; left
        // running it fires playNextEpisode() behind a dismissed player (startPlayback resets isTearingDown
        // at entry, defeating the latch). Kill every UI timer with the session.
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        liveProgramFollow?.cancel()
        liveProgramFollow = nil
        controlsTimer?.cancel()
        controlsTimer = nil
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        detailEnrichmentTask?.cancel()
        detailEnrichmentTask = nil
        scrubPreview.reset()
        let extractorToClose = frameExtractor
        frameExtractor = nil
        Task { await extractorToClose?.shutdown() }
        deactivateASSRendering()
        cancellables.removeAll()
        // Capture position BEFORE stopping: player.stop() resets currentTime to 0. Completion-aware,
        // so leaving by hand during the credits files the episode as watched instead of parking it on
        // the Continue Watching shelf with a nearly full bar.
        let finalTicks = completionAwarePositionTicks
        // Snapshot the payload + service and detach with a STRONG capture: a [weak self] task could be
        // deallocated by PlayerHostController's dismissal before the @MainActor hop ran, silently dropping
        // the position write.
        let svc = playbackService
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: finalTicks,
            liveStreamId: activeLiveStreamID
        )
        // Engine does native teardown + HLS server shutdown + AVDisplayManager criteria reset in stopInternal().
        player.stop()
        // Tuner-release safety net: frees the server-side tuner even if the stop report fails to deliver. No-op for VOD.
        releaseLiveTunerIfNeeded()
        // Fire-and-forget so the caller can start the dismiss animation without waiting on PlaybackStopped.
        // Tracked by LiveTunerGate when it carries a live stream id, because Jellyfin closes that stream
        // on PlaybackStopped too: an untracked closer is one the next tune of the same channel can
        // overtake, and the id names the channel rather than this stream (#70).
        let sessionToKill = playSessionID
        let reportWork: @Sendable () async -> Void = {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .playbackProgressDidChange,
                        object: nil,
                        userInfo: [
                            PlaybackProgressKey.itemID: stopReport.itemId,
                            PlaybackProgressKey.positionTicks: stopReport.positionTicks
                        ]
                    )
                }
            } catch {
                #if DEBUG
                print("[SessionReport] Stop FAILED: \(error)")
                #endif
            }
            // Explicit transcode kill independent of the stop report: orphaned live transcodes write an
            // endlessly growing stream.ts and fill the server disk (DELETE /Videos/ActiveEncodings, no-op when idle).
            if let sessionToKill {
                try? await svc.stopActiveEncodings(playSessionID: sessionToKill)
            }
        }
        if stopReport.liveStreamId != nil {
            LiveTunerGate.shared.close(reportWork)
        } else {
            Task.detached { await reportWork() }
        }
    }

    /// Single owner of `isLoading` at runtime (AetherEngine#85): ORs the host-load flag with the engine's
    /// `playbackPhase`. `.seeking` is left to the scrub UI. The live cold-transcode first `.playing` is
    /// premature (a stall follows ~700ms later), so a would-be clear inside that window is held and a
    /// delayed recompute settles it, preserving the old debounce without the former 15s heuristic.
    private func recomputeLoadingIndicator() {
        let wantsSpinner = PlayerLoadingIndicator.showsSpinner(hostLoadActive: hostLoadActive,
                                                               phase: player.playbackPhase,
                                                               isBuffering: player.isBuffering)
        if !wantsSpinner, isLiveSession, let firstPlay = liveFirstPlayingAt,
           Date().timeIntervalSince(firstPlay) < 0.7 {
            if !scheduledLiveSpinnerRecheck {
                scheduledLiveSpinnerRecheck = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self else { return }
                    self.scheduledLiveSpinnerRecheck = false
                    self.recomputeLoadingIndicator()
                }
            }
            return
        }
        isLoading = wantsSpinner
    }

    // MARK: - State Observation (Combine)

    private func startObserving() {
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    let firstPlay = !self.hasStartedPlaying
                    self.hasStartedPlaying = true
                    self.isPlaying = true
                    if firstPlay {
                        // Resolve the successor once the pipeline delivers frames, NOT lazily at the
                        // end window: a jump straight to the end never passes through that window, so
                        // end-of-media routed as end-of-content and closed the player (Sodalite#67).
                        self.resolveNextEpisode()
                    }
                    #if os(iOS)
                    // Take over the native volume overlay only now that playback is up; during load the
                    // native overlay stays visible so hardware volume presses always show an indicator.
                    PlayerSystemVolume.activate()
                    #endif
                    if self.isLiveSession, firstPlay {
                        // Marks the cold-transcode window; recomputeLoadingIndicator() debounces the spinner
                        // clear against it (the first .playing flips ~1s before the start segment lands, stalls,
                        // then resumes, so clearing immediately would reveal a frozen frame).
                        self.liveFirstPlayingAt = Date()
                    }
                    if self.showControls { self.scheduleControlsHide() }
                case .paused:
                    self.isPlaying = false
                    // Sodalite#93: this sink is the ONLY place that learns about every pause, including
                    // the ones raised from outside the app. See `TransportAutoHide` for why the two
                    // exceptions are the ones they are.
                    if TransportAutoHide.raisesTransport(errorVisible: self.errorMessage != nil,
                                                         inputLocked: self.isInputLocked) {
                        self.showControls = true
                    }
                case .ended:
                    // End-of-media on any backend: the engine surfaces .ended for native / software / audio
                    // alike (AetherEngine#63), so this fires uniformly without watching the AVPlayer directly.
                    self.isPlaying = false
                    // PiP: with a next episode the auto-advance path swaps the item in place (native
                    // backend, 5.12.0); real end-of-content, a cancelled advance, or a SW-backend
                    // session (Phase A, no layer-stable reload yet) closes the window and ends the
                    // session, instead of parking a black frame in the corner.
                    switch NextEpisodePolicy.endOfPlaybackOutcome(
                        hasStartedPlaying: self.hasStartedPlaying,
                        pictureInPictureActive: self.player.pictureInPictureActive,
                        pictureInPictureCanAdvance: self.pipCanAdvanceCurrentBackend,
                        hasNextEpisode: self.nextEpisode != nil,
                        advanceCancelled: self.nextEpisodeCancelled,
                        overlayDismissed: self.nextEpisodeOverlayDismissed,
                        autoplayEnabled: self.preferences.autoplayNextEpisode,
                        countdownEnabled: self.preferences.autoplayCountdown,
                        countdownRunning: self.nextEpisodeTimer != nil,
                        overlayVisible: self.showNextEpisodeOverlay
                    ) {
                    case .ignore:
                        break
                    case .endPictureInPicture:
                        self.onPiPContentEnded?()
                    case .advanceWithoutOverlay:
                        // Card dismissed, or countdown switched off: the episode was allowed to play
                        // out and the successor follows straight away (Sodalite#67).
                        LogTap.shared.note("[NextEp] end_of_media advance_without_overlay")
                        Task { @MainActor [weak self] in
                            await self?.playNextEpisode()
                        }
                    case .showOverlayAndAdvance:
                        // currentTime can stall a few seconds short of duration (demux's 15-20s
                        // look-ahead); cap the countdown at 10s so the overlay copy stays readable.
                        let remaining = self.effectiveDuration - self.playbackTime
                        let seconds = min(10, max(1, Int(ceil(max(0, remaining)))))
                        self.showNextEpisodeOverlay = true
                        self.startNextEpisodeCountdown(from: seconds)
                    case .dismissPlayer:
                        // Real end-of-content (movie / last episode), or an advance the user rejected:
                        // `.ended` is terminal in the engine (seek and play are no-ops), so an open
                        // player here would be a dead screen.
                        self.onPlaybackReachedEnd?()
                    }
                case .idle:
                    // Pure teardown (stop / new load); end-of-media is .ended now, so no next-episode trigger here.
                    self.isPlaying = false
                case .loading:
                    // Spinner is driven by playbackPhase (.loading / .rebuffering / .stalled) in
                    // recomputeLoadingIndicator(); nothing state-specific to do here now (AetherEngine#85).
                    break
                case .seeking:
                    break
                case .error(let msg):
                    // Read before anything branches: the engine assigns `errorInfo` ahead of `state`
                    // precisely so a `$state` sink can pick the classification up synchronously
                    // (AetherEngine#376), and the next state move clears it again.
                    let info = self.player.errorInfo
                    LogTap.shared.note(
                        PlayerEngineErrorPresentation.logLine(for: info, engineMessage: msg)
                    )
                    if self.isLiveSession, self.liveFirstPlayingAt == nil,
                       self.usedDirectLivePath, !self.didAttemptLiveFallback {
                        // Direct session died before first frame: consume the once-per-session fallback via
                        // the guarded retune path.
                        LogTap.shared.note("[LiveDirect] route=fallback reason=engine_error_pre_play(\(msg))")
                        self.handleLiveSourceReset()
                    } else if self.isLiveSession, self.liveFirstPlayingAt == nil,
                              self.usedLiveTunerFilePath, !self.didAbandonLiveTunerFile {
                        // Same, one route down (#70): the tuner-file read opened but never produced a
                        // frame, so spend the retreat to the static route rather than surfacing.
                        LogTap.shared.note("[LiveDirect] route=tunerfile abandoned reason=engine_error_pre_play(\(msg))")
                        self.handleLiveSourceReset()
                    } else if self.isLiveSession, self.liveFirstPlayingAt == nil {
                        // Live channel died before ever playing: friendly "unavailable" message ("Playback
                        // stopped" + raw text is for sessions that actually ran), unless the engine named
                        // something better.
                        self.setLiveChannelUnavailableError(info: info)
                    } else if self.isLiveSession {
                        // Mid-session live error: retune (recoverable like a source reset); the retune guard
                        // surfaces a friendly error once attempts are exhausted.
                        LogTap.shared.note("[Live] route=retune reason=engine_error_mid_session(\(msg))")
                        self.handleLiveSourceReset()
                    } else {
                        // Deliberately no replaced-item lookup here (tried and dropped, 2026-08-20): at the
                        // moment a *arr upgrade swaps the file, the library has removed the old item and not
                        // yet added the new one, so there is nothing to continue on, and a session that
                        // keeps trying is a session that never says anything. A dead source mid-playback
                        // gets the error screen; picking the title again is what recovers it.
                        self.setEnginePlaybackError(message: msg, info: info)
                    }
                }
            }
            .store(in: &cancellables)

        player.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.recomputeLoadingIndicator()
                self.handlePhaseForOutage(phase)
            }
            .store(in: &cancellables)

        // The spinner rule reads `isBuffering` now (a stall with the picture still running must not black
        // the screen out), so its changes have to reach the recompute the same way the phase does.
        player.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeLoadingIndicator() }
            .store(in: &cancellables)

        player.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.subtitleTime = t }
            .store(in: &cancellables)

        // Live source replay after a reconnect (Jellyfin transcode respawn re-served from the start);
        // engine parked the session and can't recover on the same URL, so re-negotiate at the live edge.
        player.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleLiveSourceReset() }
            .store(in: &cancellables)

        // Sodalite#65: the system turned captions on by itself (muted playback and the other two
        // automatic-caption triggers). The engine deselected its own rendition and hands the request
        // over; the app answers the mute case with its own subtitles.
        player.systemCaptionRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.handleSystemCaptionRequest(request) }
            .store(in: &cancellables)

        player.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.playbackTime = time
                self.closeSkipBackSubtitlesIfReached(time: time)
                // Backstop for the volume KVO, which needs an active audio session to fire and the
                // native path deliberately does not activate one. A float read per tick, and only
                // while the window is open.
                if self.systemCaptionWindow != nil {
                    self.closeSystemCaptionWindowIfAudible(volume: AVAudioSession.sharedInstance().outputVolume)
                }
                // Intro/outro/recap markers are absolute source-timeline values; currentTime is the AVPlayer
                // clock (source - playlistShiftSeconds on native HLS), so compare against sourceTime.
                self.updateSkipSegmentVisibility(time: self.player.sourceTime)
                self.updateOutroAutoSkip(time: self.player.sourceTime)
                let dur = self.effectiveDuration
                let remaining = dur - time

                // Detect backward movement (scrub-back) and reset the next-episode overlay; > 1s tolerates
                // AVPlayer jitter. The forward-trigger below re-fires naturally on the next tick.
                let movedBackward = time + 1.0 < self.lastPlaybackTimeForNextEpisode
                self.lastPlaybackTimeForNextEpisode = time
                if movedBackward, self.showNextEpisodeOverlay {
                    self.resetNextEpisodeOverlayState()
                }

                // outro.startSeconds is an absolute source-timeline marker, so the window reads
                // sourceTime; `remaining` is on the AVPlayer clock.
                let insideEndWindow = NextEpisodePolicy.isInsideTriggerWindow(
                    outroStartSeconds: self.outroSegment?.startSeconds,
                    sourceTime: self.player.sourceTime,
                    remainingSeconds: remaining
                )
                // A dismissed overlay is cancelled for THIS pass through the end window, not for the
                // session: scrubbing back out of the window releases the latch, so playing forward
                // again re-shows the overlay and re-arms auto-advance. Without this the latch survived
                // until the next episode switch, i.e. never within the current one.
                if self.nextEpisodeCancelled, !insideEndWindow {
                    self.nextEpisodeCancelled = false
                }
                // Same scope for the softer latch: the card comes back on the next pass through the
                // window, it just stays gone for this one.
                if self.nextEpisodeOverlayDismissed, !insideEndWindow {
                    self.nextEpisodeOverlayDismissed = false
                }

                if self.nextEpisode != nil && !self.nextEpisodeCancelled
                    && !self.nextEpisodeOverlayDismissed && dur > 0 && remaining > 0 {
                    // Outro available: show + fixed 10s countdown at outro.startSeconds, cutting through
                    // the credits. No outro: show at 30s remaining, countdown at 10s synced to the clock.
                    if insideEndWindow, !self.showNextEpisodeOverlay {
                        self.showNextEpisodeOverlay = true
                    }
                    if self.outroSegment != nil {
                        if insideEndWindow, self.nextEpisodeTimer == nil, self.showNextEpisodeOverlay {
                            self.startNextEpisodeCountdown()
                        }
                    } else if remaining <= 10, self.nextEpisodeTimer == nil, self.showNextEpisodeOverlay {
                        self.startNextEpisodeCountdown(from: Int(ceil(remaining)))
                    }
                }
                // Time labels track the live playhead even while scrubbing (playback keeps running); the
                // scrub target previews separately in the scrub bubble (`scrubTime`). Labels are second-
                // resolution, so only re-format/re-publish when the whole second changes (clock is 10 Hz).
                let whole = Int(max(0, time))
                if whole != self.lastDisplayedSecond {
                    self.lastDisplayedSecond = whole
                    self.currentTime = self.formatSeconds(time)
                    let rem = dur - time
                    self.remainingTime = rem > 0 ? "-\(self.formatSeconds(rem))" : "-00:00"
                }
                // Progress bar + warmed frame must NOT follow the live clock during a scrub (would fight scrubProgress).
                guard !self.isScrubbing else { return }
                // Live owns `progress` via the DVR baseline in observeLiveEdge (live duration is 0). Leave VOD untouched.
                if !self.isLiveSession {
                    self.progress = dur > 0 ? Float(time / dur) : 0
                }
                // Keep one frame warm at the playhead so the first scrub frame is instant.
                // Skip while the spinner is up (startup / rebuffer / stall): for DV/4K sources
                // with no server trickplay, warm() spins up a second demuxer + a full software
                // HEVC decode that needlessly competes with the pipeline for CPU and I/O during
                // the exact window playback is trying to become ready. (The DV "loads forever"
                // hang itself was an engine backpressure wedge, fixed separately; this only
                // removes the contention.) Scrub-start prewarm() still covers cold-start latency.
                if !self.isLoading {
                    self.scrubPreview.warm(toSeconds: time)
                }
            }
            .store(in: &cancellables)

        player.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                guard let self else { return }
                self.totalTime = dur > 0 ? self.formatSeconds(dur) : "00:00"
                // remainingTime is gated on the whole-second change in the clock sink; force a refresh
                // on the next tick so a late-resolving duration updates the label without a ~1s lag.
                self.lastDisplayedSecond = -1
            }
            .store(in: &cancellables)

        player.clock.$bufferedPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pos in
                guard let self else { return }
                self.bufferedProgress = Self.bufferedProgressValue(
                    bufferedPosition: pos, duration: self.effectiveDuration, isLive: self.isLiveSession)
            }
            .store(in: &cancellables)

        player.$videoFormat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format in
                guard let self else { return }
                // Log videoFormat transitions for TestFlight diagnostics (engine sources it from the demuxer
                // probe + late-discovered HDR10+ T.35 SEI mid-stream).
                if format != self.videoFormat {
                    let line = "[PlayerVM] videoFormat changed: \(self.videoFormat) → \(format)"
                    print(line)
                    LogTap.shared.note(line)
                }
                // AE#459: no second clamp here. The engine already publishes what the PANEL presents
                // (`presentedVideoFormat`), and this one asked the wrong question: tvOS reports Match
                // Dynamic Range and Match Frame Rate through one combined flag, so an Apple TV whose output
                // format is fixed to HDR with matching off was relabelled SDR while it was demonstrably
                // showing HDR, and it would have overridden the engine's late panel probe right back.
                self.videoFormat = format
            }
            .store(in: &cancellables)

        // Mirror engine cues into `subtitleCues` only when the engine is the source. The legacy HTTP path
        // (bitmap / transcode) writes subtitleCues directly with isSubtitleActive == false, so the guard
        // keeps the two paths from clobbering each other.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                guard self.player.isSubtitleActive else { return }
                self.subtitleCues = ForcedSubtitleFallback.filteredCues(cues, mode: self.forcedSubtitleFallback)
            }
            .store(in: &cancellables)

        // Secondary companion subtitle cues (issue #47); same mirror contract as the primary sink.
        player.$secondarySubtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                guard self.player.isSecondarySubtitleActive else { return }
                self.secondarySubtitleCues = cues
            }
            .store(in: &cancellables)

        // Engine is the source of truth for the active audio track; mirror it so the picker reflects what
        // the pipeline settled on (not the requested track mid-reload, which made early scrubs look broken).
        player.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                self?.activeAudioIndex = index
            }
            .store(in: &cancellables)

        // Live has no Jellyfin stream list (the live load returns before the VOD mapping), so the
        // engine's own table is the session's subtitle source. Reactive, not a read after load: a
        // broadcast stream can surface a subtitle track late, and a channel switch replaces the list.
        player.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self, self.isLiveSession else { return }
                let mapped = LiveSubtitleTracks.mediaStreams(from: tracks)
                let indices = mapped.map(\.index)
                guard indices != self.lastLiveSubtitleIndices else { return }
                self.lastLiveSubtitleIndices = indices
                self.subtitleStreams = mapped
                // The empty case is logged too. A channel delivered as a server transcode carries no
                // subtitle stream at all, which is a routing answer, not a failure, and a diagnostic
                // that stays silent there reads exactly like a sink that never fired.
                let detail = mapped.isEmpty ? "" : ": " + mapped
                    .map { "\($0.index):\($0.codec ?? "?")/\($0.language ?? "und")" }
                    .joined(separator: ", ")
                LogTap.shared.note("[LiveSubs] engine published \(mapped.count) subtitle track(s)\(detail)")
                // First real list of the session: apply the same automatic pick VOD gets. The audio
                // track is settled by now, so the foreign-audio rule works here; as a pre-load
                // LoadOptions language list it could not have been expressed at all.
                guard !mapped.isEmpty, !self.didAutoSelectLiveSubtitle else { return }
                self.didAutoSelectLiveSubtitle = true
                let audioLanguage = self.player.audioTracks
                    .first(where: { $0.id == self.player.activeAudioTrackIndex })?.language
                self.applyPreferredSubtitle(forAudioLanguage: audioLanguage)
            }
            .store(in: &cancellables)
    }

    // MARK: - Controls

    /// True while a post-background pipeline reload is in flight. The reload auto-plays, then policy
    /// pauses ("don't auto-resume after a Home/sleep gap"); but if the user pressed Play during the
    /// slow reload that intent wins and the trailing pause must be skipped (else "play does nothing").
    private(set) var isAwaitingBackgroundReload = false
    private var userToggledDuringBackgroundReload = false

    /// Mark the start of the post-background reload window; call before awaiting `reloadAtCurrentPosition()`.
    func beginBackgroundReload() {
        isAwaitingBackgroundReload = true
        userToggledDuringBackgroundReload = false
    }

    /// Apply post-reload pause policy: hold paused on the resumed frame UNLESS the user toggled
    /// play/pause during the reload (their intent wins). Surfaces controls either way.
    func finishBackgroundReload() {
        let userIntervened = userToggledDuringBackgroundReload
        isAwaitingBackgroundReload = false
        userToggledDuringBackgroundReload = false
        if !userIntervened { player.pause() }
        showControlsTemporarily()
    }

    func togglePlayPause() {
        if isAwaitingBackgroundReload { userToggledDuringBackgroundReload = true }
        player.togglePlayPause()
        reportProgressIfNeeded()
        showControls = true
        scheduleControlsHide()
    }

    /// Seek by the user's configured interval; direction +1 (right) or -1 (left). Wraps the seconds
    /// variant so the press handler doesn't need a Preferences lookup.
    func seekJumpByConfiguredInterval(direction: Int) {
        let interval = preferences.skipIntervalSeconds
        let signed = (direction < 0 ? -1 : 1) * interval
        seekJump(seconds: Double(signed))
    }

    func seekJump(seconds: Double) {
        let dur = scrubReferenceDuration
        guard dur > 0 else { return }

        // Sodalite#63: remember where a backward jump started so the commit can open the subtitle
        // window. A forward jump abandons a pending origin rather than extending it. Both jump gestures
        // pass through here (tvOS interval press, iOS double tap); pan and hold-to-seek do not.
        if seconds < 0 {
            // Sodalite#65: the burst's own origin, which outlives the commit that consumes the
            // per-commit one. Without it, press four of a burst would measure its 10 s against the
            // position press three landed on and reopen a window the burst had just outgrown.
            skipBackBurstOrigin = SkipBackSubtitleWindow.burstOrigin(
                previous: skipBackBurstOrigin,
                playhead: playbackTime,
                secondsSinceLastJump: lastBackwardJumpAt.map { Date().timeIntervalSince($0) })
            pendingSkipBackOrigin = skipBackBurstOrigin
            // iOS answers a skip back with a caption request of its own; stamp the jump so that
            // request is read as what it is instead of as muted playback.
            lastBackwardJumpAt = Date()
        } else {
            pendingSkipBackOrigin = nil
            skipBackBurstOrigin = nil
        }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            scrubProgress = progress
        }

        showControls = true
        controlsTimer?.cancel()

        let jumpProgress = Float(seconds / dur)
        scrubProgress = max(0, min(1, scrubProgress + jumpProgress))
        // scrubTime is VOD-only (live bar renders its own behind-live label); preview is fed for live
        // via updateLiveScrubPreview (DVR-cache thumbnails).
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else { updateLiveScrubPreview() }

        // Sodalite#114 (was the opt-in of #60): the press IS the seek and the transport rising is its
        // feedback, the way the system player behaves. The short idle is what makes three quick presses
        // one seek rather than three restarts, and it keeps a press landing mid-seek from computing its
        // target off a stale position.
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(Self.skipCommitDelay))
            guard !Task.isCancelled else { return }
            commitScrub()
        }
    }

    /// Idle window a left/right press waits before it seeks, so a burst of presses coalesces into a
    /// single seek.
    static let skipCommitDelay: Double = 0.3

    /// Reset the error trio so a fresh `startPlayback` shows nothing stale while loading.
    func clearError() {
        errorMessage = nil
        errorIcon = nil
        errorTitle = nil
        canRetryAfterOutage = false
        errorFocus = .back
    }

    // MARK: - Error screen input (tvOS press machine)

    /// Horizontal step on the error screen.
    func moveErrorFocus(by direction: Int) {
        errorFocus = errorFocus.stepped(by: direction, hasRetry: canRetryAfterOutage)
    }

    /// What the Select press on the error screen resolved to. Retry is performed here; dismissing the
    /// player belongs to the host, which owns the modal.
    enum ErrorAction { case retried, dismiss }

    func commitErrorFocus() -> ErrorAction {
        guard errorFocus == .retry, canRetryAfterOutage else { return .dismiss }
        retryAfterOutage()
        return .retried
    }

    /// Categorise a playback-start error into an icon + title + body trio for the overlay; body stays
    /// the underlying localizedDescription so the user sees the real reason.
    func setError(from error: Error) {
        let icon: String
        let title: String
        if let api = error as? APIError {
            switch api {
            case .serverUnreachable:
                icon = "wifi.exclamationmark"
                title = String(localized: "player.error.connection.title", defaultValue: "Connection problem")
            case .networkError:
                icon = "wifi.exclamationmark"
                title = String(localized: "player.error.connection.title", defaultValue: "Connection problem")
            case .timeout:
                icon = "clock.badge.exclamationmark"
                title = String(localized: "player.error.timeout.title", defaultValue: "Request timed out")
            case .unauthorized:
                icon = "lock.shield"
                title = String(localized: "player.error.unauthorized.title", defaultValue: "Sign-in required")
            case .httpError(let statusCode, _):
                if statusCode == 404 {
                    icon = "questionmark.folder"
                    title = String(localized: "player.error.notFound.title", defaultValue: "Item unavailable")
                } else if (500..<600).contains(statusCode) {
                    icon = "server.rack"
                    title = String(localized: "player.error.server.title", defaultValue: "Server error")
                } else {
                    icon = "exclamationmark.triangle"
                    title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
                }
            case .localNetworkDenied:
                // Named rather than folded into the connection face: the whole point of Sodalite#92
                // is that this failure is not a connection problem, and the overlay under this title
                // carries the sentence that says where the switch is.
                icon = "network.slash"
                title = String(localized: "localNetwork.denied.title", defaultValue: "Local Network access is off")
            case .invalidURL, .invalidResponse, .decodingError:
                icon = "exclamationmark.triangle"
                title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
            }
        } else if let engine = error as? PlayerEngineError {
            switch engine {
            case .noSource, .noURL:
                icon = "questionmark.video"
                title = String(localized: "player.error.noVideo.title", defaultValue: "Couldn't open this video")
            case .liveAudioUnsupported:
                // Its own headline rather than "Channel unavailable": the advice is the opposite of
                // every other live error, since no retry and no server setting can decode AC-4 (#100).
                icon = "waveform.slash"
                title = String(
                    localized: "player.error.liveAudioUnsupported.title",
                    defaultValue: "Channel not supported"
                )
            }
        } else {
            icon = "exclamationmark.triangle"
            title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
        }
        errorIcon = icon
        errorTitle = title
        errorMessage = ErrorText.user(for: error)
    }

    /// A start failure, painted from the engine's classification where it has one.
    ///
    /// `setError(from:)` can only read the thrown error, and what `player.load()` throws is opaque: its
    /// `localizedDescription` is the engine's own English sentence ("Origin answered HTTP 400 for the
    /// source"), which in a 26-language app is an untranslated string describing the plumbing. The typed
    /// `errorInfo` beside it is the part that classifies, and the host already has localized copy for
    /// every face it names. Where the classification has no face worth the swap, the start-failure trio
    /// stays exactly as it was.
    func setStartError(_ error: Error, engineInfo: PlaybackErrorInfo?) {
        let face = PlayerEngineErrorPresentation.face(for: engineInfo)
        guard face != .engineMessage else {
            setError(from: error)
            return
        }
        let trio = PlayerEngineErrorPresentation.trio(
            for: face,
            engineMessage: ErrorText.user(for: error),
            context: .start
        )
        errorIcon = trio.icon
        errorTitle = trio.title
        errorMessage = trio.message
    }

    /// Friendly trio for a live channel the server can't deliver (dead upstream); covers engine-level
    /// open failures where the raw message would be noise. Network/auth APIErrors keep setError(from:).
    ///
    /// "Unavailable" is the fallback, not the verdict: where the engine typed the failure, that naming wins
    /// (a refusal and an origin out of connection slots are not the channel being off the air).
    func setLiveChannelUnavailableError(info: PlaybackErrorInfo? = nil) {
        let trio = PlayerEngineErrorPresentation.trio(
            for: PlayerEngineErrorPresentation.liveFace(for: info),
            engineMessage: ""
        )
        errorIcon = trio.icon
        errorTitle = trio.title
        errorMessage = PlayerEngineErrorPresentation.appendingReportCode(to: trio.message, from: info)
    }

    /// Engine-side terminal error mid-playback (decoder/renderer death, network drop after handoff).
    ///
    /// With an `info` the host writes its own localized sentence for the failures it can name (a refused
    /// stream, a missing file, a metered origin, Dolby Vision this device cannot decode); without one, or
    /// for a kind this build does not recognise, the headline reads "stopped" and the engine's own text
    /// stays the body, which is also what the two live call sites want, since they pass a sentence they
    /// already localized themselves.
    func setEnginePlaybackError(message: String, info: PlaybackErrorInfo? = nil) {
        let trio = PlayerEngineErrorPresentation.trio(
            for: PlayerEngineErrorPresentation.face(for: info),
            engineMessage: message
        )
        errorIcon = trio.icon
        errorTitle = trio.title
        errorMessage = trio.message
    }

    // MARK: - Source outage

    /// Engine phase changed: drive the connection chip and arm / disarm the server probe.
    ///
    /// `.stalled` is the reader's network axis, so it is the only phase that says "the source is not
    /// delivering". Everything else means the reader is fine and whatever it was fighting is over.
    private func handlePhaseForOutage(_ phase: PlaybackPhase) {
        let stalled = PlayerLoadingIndicator.showsConnectionNotice(hostLoadActive: hostLoadActive, phase: phase)
        updateConnectionNotice(stalled: stalled)
        outageWatchdogIfNeeded()?.phaseChanged(to: phase)
    }

    private func updateConnectionNotice(stalled: Bool) {
        connectionNoticeTask?.cancel()
        connectionNoticeTask = nil
        guard stalled else {
            showsConnectionNotice = false
            return
        }
        guard !showsConnectionNotice else { return }
        connectionNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PlayerViewModel.connectionNoticeDelay))
            guard !Task.isCancelled, let self else { return }
            self.showsConnectionNotice = true
        }
    }

    /// Built on first use because it needs nothing else from the session: a player that never stalls never
    /// creates one. Nil when the service has no base URL, which also means no probe can be trusted, so no
    /// outage is ever called.
    private func outageWatchdogIfNeeded() -> SourceOutageWatchdog? {
        if let outageWatchdog { return outageWatchdog }
        guard let base = playbackService.baseURL else { return nil }
        let watchdog = SourceOutageWatchdog(
            probe: { await ServerProbe.jellyfin(base) },
            onOutage: { [weak self] in self?.handleSourceOutage() }
        )
        outageWatchdog = watchdog
        return watchdog
    }

    /// The app left / returned to the foreground. iOS keeps playing audio in the background on purpose
    /// (AetherEngine#127 grace, PiP), so a session the user cannot see must not be torn down over a probe.
    func setAppActive(_ active: Bool) {
        outageWatchdog?.setActive(active)
    }

    /// The server stopped answering while the reader was stalled. The engine would reach the same verdict
    /// on its own, but only after its reconnect ladder and two revives, i.e. minutes of spinner.
    private func handleSourceOutage() {
        guard errorMessage == nil, !isTearingDown else { return }
        LogTap.shared.note("[Outage] server unreachable while stalled; pausing and surfacing terminal error")
        serverConfirmedUnreachable = true
        outageResumeSeconds = isLiveSession ? nil : playbackTime
        // Pause rather than stop: it silences the audio that was still draining out of the segment cache
        // while leaving the session intact for a retry, and it keeps the normal teardown path in charge of
        // the stop report.
        player.pause()
        isPlaying = false
        hostLoadActive = false
        updateConnectionNotice(stalled: false)
        setServerUnreachableError(host: playbackService.baseURL?.host ?? "")
    }

    /// Terminal trio for a confirmed server outage. Distinct from `setEnginePlaybackError` because this one
    /// names a cause the viewer can act on, and it is the only error that offers a retry.
    private func setServerUnreachableError(host: String) {
        errorIcon = "wifi.exclamationmark"
        errorTitle = String(
            localized: "player.error.serverLost.title",
            defaultValue: "Connection to the server lost"
        )
        errorMessage = String(
            format: String(
                localized: "player.error.serverLost.body",
                defaultValue: "Sodalite can no longer reach %@. Playback was paused, your position is kept."
            ),
            host
        )
        canRetryAfterOutage = true
        errorFocus = .initial(hasRetry: true)
    }

    /// "Try again" on the outage screen: re-runs the whole session against the server, resuming where the
    /// outage hit. The cached PlaybackInfo is dropped on purpose, a restarted server knows nothing about
    /// that play session.
    func retryAfterOutage() {
        guard canRetryAfterOutage else { return }
        LogTap.shared.note("[Outage] retry requested at \(String(format: "%.1f", outageResumeSeconds ?? 0))s")
        canRetryAfterOutage = false
        serverConfirmedUnreachable = false
        outageWatchdog?.reset()
        cachedPlaybackInfo = nil
        resumeOverrideSeconds = outageResumeSeconds
        outageResumeSeconds = nil
        // Live recovery counts its own attempts; a manual retry is not one of the automatic retunes.
        liveRetuneCount = 0
        lastLiveRetuneAt = nil
        clearError()
        player.stop()
        beginPlayback()
    }

    /// Reload after the library answered a failed session: same shape as `retryAfterOutage`, different
    /// reason, so the two stay side by side. `seconds` carries the position a replaced item cannot carry
    /// itself (the new file is a new item, its own userData starts at zero).
    func restartAfterItemRecovery(resumeAt seconds: Double?) {
        canRetryAfterOutage = false
        serverConfirmedUnreachable = false
        outageWatchdog?.reset()
        cachedPlaybackInfo = nil
        resumeOverrideSeconds = seconds
        clearError()
        player.stop()
        beginPlayback()
    }

    /// Apply `pictureMode` to whichever layer is on screen: writes to the engine AND fires
    /// `onPictureModeChanged` so the host mirrors the gravity onto AVKit's own AVPlayerLayer (the layer
    /// actually on screen for the native path, where without the callback the toggle is a no-op).
    func applyPictureMode() {
        switch pictureMode {
        case .original: player.videoGravity = .resizeAspect
        case .fill:     player.videoGravity = .resizeAspectFill
        }
        onPictureModeChanged?(pictureMode)
    }

    /// Fired when `applyPictureMode` resolves a new gravity; PlayerHostController hooks it to update
    /// AVPlayerViewController's own `videoGravity` (the native path's rendering).
    var onPictureModeChanged: ((PlaybackPreferences.PictureMode) -> Void)?

    /// Fired after every primary-subtitle selection (including "off"). Sodalite#98: the external-display
    /// subtitle window gates on a selection being active, so turning subtitles on mid-playback has to
    /// re-evaluate that decision; without this it only re-ran on route or serving-state changes.
    var onSubtitleSelectionChanged: (() -> Void)?

    /// In-player picker change; mutates session-local `pictureMode` and pushes to the engine. Not persisted.
    func selectPictureMode(_ mode: PlaybackPreferences.PictureMode) {
        pictureMode = mode
        applyPictureMode()
    }

    /// Seek to a chapter start. Index is into the sorted `chapters`; out-of-range no-ops.
    func selectChapter(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        let target = chapters[index].startSeconds
        Task { [weak self] in await self?.player.seek(to: target) }
    }

    /// Jump to the start of the current item and play. Live is excluded: tvOS renders LiveTransportBar
    /// there and the iOS icon row hides the button, this guard is the second line of defence.
    func restartFromBeginning() {
        guard !isLiveSession else { return }
        Task { [weak self] in
            await self?.player.seek(to: 0)
            guard let self else { return }
            if !isPlaying { player.play() }
            // Move Jellyfin's resume point to 0 now: closing the player right after the restart
            // would otherwise restore the pre-restart position on the next open.
            reportProgressIfNeeded()
            scheduleControlsHide()
        }
    }

    func selectAudioTrack(id: Int, userInitiated: Bool = false) {
        let action = LiveAudioSwitch.action(requestedIndex: id,
                                            activeIndex: activeAudioIndex,
                                            isLive: isLiveSession,
                                            retuneInFlight: liveRetuneInFlight)
        guard action != .ignore else { return }
        if userInitiated, let key = memoryScopeKey,
           let track = player.audioTracks.first(where: { $0.id == id }) {
            trackMemory?.recordAudio(TrackSelectionMatcher.audioSignature(track), for: key)
        }
        if case .retune(let streamIndex) = action {
            switchLiveAudioTrack(streamIndex: streamIndex)
            return
        }
        // No optimistic `activeAudioIndex = id`: the $activeAudioTrackIndex sink updates the picker once
        // the engine settles, else it claims the switch happened while the pipeline is still mid-reload.
        player.selectAudioTrack(index: id)
        // Re-run auto-subtitle resolution so a manual mid-playback language switch behaves like load-time
        // (else DE → EN kept subs off even though autoSubtitleForForeignAudio would have turned them on).
        let language = player.audioTracks.first(where: { $0.id == id })?.language
        applyPreferredSubtitle(forAudioLanguage: language)
        // The forced fallback is language-bound; re-resolve it for the new audio (a no-op when a
        // subtitle is actively selected). The engine hasn't settled the switch yet, so resolve
        // against the REQUESTED track's language, not activeAudioTrackIndex.
        applyForcedSubtitleFallback(audioLanguageOverride: language)
    }

    /// Dedupes subtitle streams: one EMBEDDED track per (language, codec), but descriptor variants
    /// (SDH/Forced/commentary) keep their own slot. EXTERNAL subs (sidecars, downloads) are never
    /// collapsed (each is a distinct user-curated file). Shared by initial load + post-download refetch.
    static func dedupedSubtitleStreams(from mediaStreams: [MediaStream]?) -> [MediaStream] {
        let allSubStreams = mediaStreams?.filter { $0.type == .subtitle } ?? []
        var seen = Set<String>()
        return allSubStreams.filter { stream in
            if stream.isExternal == true { return true }
            let lang = stream.language ?? "und"
            let hasDescriptor = stream.isForced == true
                || (stream.title?.lowercased()).map { t in
                    ["sdh", "commentary", "cc", "signs", "songs", "hearing", "forced", "musik", "music", "full"].contains(where: { t.contains($0) })
                } ?? false
            let codecKey = stream.codec?.lowercased() ?? ""
            let key = hasDescriptor
                ? "\(lang)_\(stream.title ?? "")_\(codecKey)"
                : "\(lang)_\(codecKey)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    /// AE#88: external Jellyfin subtitle streams as engine load declarations plus the
    /// streamIndex -> engine-track-id map. Engine guarantee: LoadOptions.externalSubtitles[i]
    /// gets id externalSubtitleTrackIDBase + i.
    static func externalSubtitleDescriptors(
        streams: [MediaStream],
        urlBuilder: (MediaStream) -> URL?
    ) -> (descriptors: [ExternalSubtitleTrack], mapping: [Int: Int]) {
        var descriptors: [ExternalSubtitleTrack] = []
        var mapping: [Int: Int] = [:]
        for stream in streams where stream.isExternal == true {
            guard let url = urlBuilder(stream) else { continue }
            mapping[stream.index] = AetherEngine.externalSubtitleTrackIDBase + descriptors.count
            descriptors.append(ExternalSubtitleTrack(
                url: url,
                name: stream.title ?? stream.displayTitle,
                language: stream.language,
                isForced: stream.isForced == true,
                formatHint: stream.codec))
        }
        return (descriptors, mapping)
    }

    /// Resolves which subtitle to surface for the active audio language:
    /// 1. Explicit `preferredSubtitleLanguage` always wins.
    /// 2. Else if `autoSubtitleForForeignAudio` and audio isn't the preferred language, surface subs
    ///    in the preferred audio language (the "Netflix convention").
    /// 3. No match → leave the current selection alone (may be a manual user pick).
    ///
    /// Live has one exception, on the first rule only: a broadcast subtitle stream routinely states
    /// no language, so a configured language matches nothing on the channels that do carry subtitles.
    /// An unlabelled track is then taken to be the broadcast's own, the same reading the temporary
    /// windows use. It stays tied to the explicit setting, i.e. to someone having asked for subtitles
    /// in the first place: rule 2 fires on foreign audio, which an untagged track cannot establish,
    /// and switching subtitles on for a viewer who configured nothing would be an answer to a
    /// question nobody asked.
    private func applyPreferredSubtitle(forAudioLanguage audioLanguage: String?) {
        if let explicit = preferences.preferredSubtitleLanguage {
            if let match = bestSubtitleMatch(forLanguage: explicit) {
                selectSubtitleTrack(id: match.index)
            } else if isLiveSession,
                      let unlabelled = SkipBackSubtitleWindow.bestUnlabelledSubtitle(streams: subtitleStreams) {
                LogTap.shared.note(
                    "[LiveSubs] no track in \(explicit), taking unlabelled stream \(unlabelled)")
                selectSubtitleTrack(id: unlabelled)
            }
            return
        }
        guard preferences.autoSubtitleForForeignAudio,
              let preferredAudio = effectivePreferredAudioLanguage(),
              Self.audioCountsAsForeign(audioLanguage: audioLanguage, preferredAudio: preferredAudio)
        else { return }
        if let match = bestSubtitleMatch(forLanguage: preferredAudio) {
            selectSubtitleTrack(id: match.index)
        }
    }

    /// nil when the memory is disabled or unavailable, which turns every read and write
    /// below into a no-op without a second flag to check.
    var memoryScopeKey: String? {
        guard preferences.rememberTrackSelections, trackMemory != nil, !isLiveSession else { return nil }
        return TrackSelectionMemory.scopeKey(userID: userID, itemID: item.id, seriesID: item.seriesId)
    }

    /// Sodalite#46: a remembered pick for this movie or series beats both
    /// `preferredSubtitleLanguage` and `autoSubtitleForForeignAudio`; anything the memory
    /// cannot resolve falls through to that automatic resolution unchanged. VOD only, the
    /// live path keeps calling `applyPreferredSubtitle` directly.
    private func resolveInitialTracks(audioLanguage: String?) {
        let entry = memoryScopeKey.flatMap { trackMemory?.entry(for: $0) }
        let plan = TrackSelectionMatcher.plan(
            entry: entry,
            subtitleStreams: subtitleStreams,
            audioTracks: player.audioTracks
        )

        // Raw engine select, not selectAudioTrack: the wrapper re-runs the automatic
        // subtitle resolution, which would overwrite the remembered subtitle below.
        if let audioTrackID = plan.audioTrackID, audioTrackID != player.activeAudioTrackIndex {
            player.selectAudioTrack(index: audioTrackID)
        }

        switch plan.subtitle {
        case .off:
            selectSubtitleTrack(id: nil)
        case .select(let streamIndex):
            selectSubtitleTrack(id: streamIndex)
        case .fallThrough:
            applyPreferredSubtitle(forAudioLanguage: audioLanguage)
        }
    }

    /// Disc parity: with subtitles OFF, silently feed a forced source into the overlay so forced
    /// captions (signs, foreign dialogue) still show, like a disc player would. Engine-silent by
    /// design: `activeSubtitleIndex` stays nil (picker keeps "Off"), reporting is untouched, only
    /// `activeSubtitleCodec` is set so a forced ASS track still gets its markup stripped. Re-run
    /// after every subtitle/audio resolution; a no-op when a subtitle is user-selected. Skipped on
    /// transcode (HLS rewrites stream indices; the legacy loader owns cues there).
    private func applyForcedSubtitleFallback(audioLanguageOverride: String? = nil) {
        let previous = forcedSubtitleFallback
        guard activeSubtitleIndex == nil, activePlayMethod != .transcode else {
            forcedSubtitleFallback = .none
            return
        }
        let audioLanguage = audioLanguageOverride ?? player.audioTracks
            .first(where: { $0.id == player.activeAudioTrackIndex })?.language
        var mode = ForcedSubtitleFallback.resolve(
            streams: subtitleStreams,
            audioLanguage: audioLanguage,
            enabled: preferences.autoForcedSubtitles
        )

        switch mode {
        case .forcedTrack(let index):
            let stream = subtitleStreams.first(where: { $0.index == index })
            if stream?.isExternal == true {
                if let engineID = engineTrackID(forExternalStream: stream, jellyfinIndex: index) {
                    player.selectSubtitleTrack(index: engineID)
                } else {
                    mode = .none
                }
            } else {
                player.selectSubtitleTrack(index: index)
            }
            activeSubtitleCodec = stream?.codec?.lowercased()
        case .cueFilter(let index):
            player.selectSubtitleTrack(index: index)
            activeSubtitleCodec = subtitleStreams.first(where: { $0.index == index })?.codec?.lowercased()
        case .none:
            if previous != .none {
                player.clearSubtitle()
                subtitleCues = []
                activeSubtitleCodec = nil
            }
        }
        forcedSubtitleFallback = mode
        if mode != previous {
            let line = "[PlayerVM] forced-subtitle fallback: \(mode) (audio=\(audioLanguage ?? "nil"))"
            print(line)
            LogTap.shared.note(line)
        }
    }

    /// #32 / #34: toggle the native subtitle rendition's VISIBILITY via textStyleRules instead of deselecting it.
    /// A deselect detaches AVKit's legible renderer and it does NOT re-attach on a later entry after a
    /// seek/producer-restart (device-confirmed). Keeping the rendition selected + rendering (transparent in
    /// fullscreen, where the on-frame overlay draws instead) keeps the renderer continuously attached, so it
    /// survives fullscreen<->PiP/external and seeks. `nil` = default AVKit legible styling (visible).
    ///
    /// Sodalite#65: the invisible rule was incomplete. Foreground and CharacterBackground only cover the
    /// glyphs and the fill behind them; the box AROUND them is `kCMTextMarkupAttribute_BackgroundColorARGB`
    /// ("the color applies to the geometry (e.g., a box) containing the text", CMTextMarkup.h), and it was
    /// left at the renderer's default. When iOS turned captions on by itself (automatic captions on mute)
    /// the result was an empty grey box over the frame: invisible text inside a box nobody had styled.
    func setNativeSubtitleRenditionVisible(_ visible: Bool) {
        guard Self.nativeSubtitleRenditionEnabled, let item = player.currentAVPlayer?.currentItem else { return }
        if visible {
            item.textStyleRules = nil
        } else if let transparent = AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0]
        ]) {
            item.textStyleRules = [transparent]
        }
    }

    /// #32: true once the native rendition has been selected this session. The select (deselect/reselect dance)
    /// must run ONCE to attach the renderer; re-running it on a later entry would detach it and not re-attach
    /// after a seek. Reset when the item is rebuilt (load) or the user changes subtitle.
    ///
    /// AE#227: also gates the on-frame overlay. While the rendition renders (PiP, AirPlay, external display),
    /// AVKit draws the same lines, and this device drew them a second time underneath: the sending iPhone
    /// showed subtitles over its AirPlay placeholder, and returning from the route double-drew them for a
    /// moment. The engine's own host guidance is to hide the overlay for exactly this window.
    private(set) var nativeSubtitleRenderingActive = false

    /// Video left the app's view hierarchy (a PiP window, an AirPlay receiver, or a wired external display):
    /// select the native rendition matching the user's active subtitle so AVKit renders it itself, and make it
    /// visible (default styling).
    func enterNativeSubtitleRendering() {
        guard Self.nativeSubtitleRenditionEnabled else { return }
        setNativeSubtitleRenditionVisible(true)
        player.setNativeSubtitleRendering(true)
        nativeSubtitleRenderingActive = true
    }

    /// Video returned to fullscreen inside the app: deselect the native rendition so it does not render; the
    /// on-frame overlay owns subtitles again.
    func exitNativeSubtitleRendering() {
        guard Self.nativeSubtitleRenditionEnabled else { return }
        player.setNativeSubtitleRendering(false)
        nativeSubtitleRenderingActive = false
    }

    /// Drop the native rendering selection state so the next entry re-selects (item rebuilt, or subtitle changed).
    func resetNativeSubtitleRenderingState() {
        nativeSubtitleRenderingActive = false
    }

    /// Picks the most useful subtitle in a language for following dialog: full > SDH/CC > forced;
    /// signs/songs/commentary excluded. `min(by:)` is stable so ties keep source order.
    private func bestSubtitleMatch(forLanguage language: String) -> MediaStream? {
        let candidates = subtitleStreams.filter {
            Self.languagesMatch($0.language, language)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min(by: {
            Self.subtitleAutoPickRank($0) < Self.subtitleAutoPickRank($1)
        })
    }

    /// Lower rank wins (see `bestSubtitleMatch`). `descriptorRank * 2 + bitmapPenalty` keeps the
    /// descriptor axis (full > SDH > forced > signs/songs) dominant, codec (text < bitmap) a tiebreaker:
    /// full bitmap beats forced text (coverage > styling), full text beats full bitmap (user styling
    /// only applies to text cues).
    static func subtitleAutoPickRank(_ stream: MediaStream) -> Int {
        let title = stream.title?.lowercased() ?? ""
        let descriptorRank: Int = {
            let isSpecialPurpose = ["signs", "songs", "music", "musik", "commentary"]
                .contains(where: { title.contains($0) })
            if isSpecialPurpose { return 3 }
            let isForced = stream.isForced == true || title.contains("forced")
            if isForced { return 2 }
            let isSDH = ["sdh", "cc", "hearing"]
                .contains(where: { title.contains($0) })
            if isSDH { return 1 }
            return 0
        }()
        let codec = stream.codec?.lowercased() ?? ""
        let isBitmap = ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub", "xsub"]
            .contains(where: { codec.contains($0) })
        return descriptorRank * 2 + (isBitmap ? 1 : 0)
    }

    /// Effective preferred audio language for foreign-audio detection. Settings' "Auto" stores nil; we
    /// substitute the device's primary language code so "Auto" still gives auto-subs (else the guard
    /// has nothing to compare against).
    // Not private: the +Live extension (separate file) reads it to seed LoadOptions.preferredAudioLanguages.
    func effectivePreferredAudioLanguage() -> String? {
        if let explicit = preferences.preferredAudioLanguage {
            return explicit
        }
        return Locale.current.language.languageCode?.identifier
    }

    /// Whether the audio should count as foreign for the automatic-subtitle rule.
    ///
    /// Unknown is NOT foreign. `languagesMatch` answers false for a missing tag, so an untagged track
    /// satisfied "the audio is not in your language" and pulled subtitles up on any stream that
    /// carries no language at all. Live HLS audio renditions never carry one, so every channel came up
    /// with subtitles on for a viewer who had merely left everything on automatic.
    static func audioCountsAsForeign(audioLanguage: String?, preferredAudio: String?) -> Bool {
        guard let preferredAudio,
              let audioLanguage,
              !audioLanguage.isEmpty,
              audioLanguage.lowercased() != "und"
        else { return false }
        return !languagesMatch(audioLanguage, preferredAudio)
    }

    /// Loose language-tag comparison so settings ("ger"), container metadata ("deu"), and BCP-47 ("de")
    /// line up; without it auto-subtitles silently failed when codes differed in format.
    /// Whether a track states no language at all: nil, empty, or `und`, the ISO code for undetermined
    /// (the container saying it does not know). Broadcasters tag live streams that way routinely, so
    /// the answer decides real behaviour rather than only a label. One description, because three
    /// call sites had grown their own identical copy of it.
    static func isLanguageUnknown(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        return language.lowercased() == "und"
    }

    static func languagesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased() else { return false }
        if a == b { return true }
        return languageSynonyms.contains { $0.contains(a) && $0.contains(b) }
    }

    /// ISO 639-1 / 639-2/T / 639-2/B equivalence classes; anything outside falls back to strict equality.
    private static let languageSynonyms: [Set<String>] = [
        ["de", "deu", "ger"], ["en", "eng"], ["fr", "fra", "fre"],
        ["es", "spa"], ["it", "ita"], ["ja", "jpn"], ["ko", "kor"],
        ["zh", "zho", "chi"], ["pt", "por"], ["ru", "rus"],
        ["nl", "nld", "dut"], ["sv", "swe"], ["da", "dan"],
        ["no", "nor"], ["nb", "nob"], ["nn", "nno"],
        ["fi", "fin"], ["pl", "pol"], ["cs", "ces", "cze"],
        ["hu", "hun"], ["tr", "tur"], ["el", "ell", "gre"],
        ["ar", "ara"], ["he", "heb"], ["hi", "hin"], ["id", "ind"],
        ["th", "tha"], ["vi", "vie"], ["uk", "ukr"], ["ro", "ron", "rum"],
        ["sk", "slk", "slo"], ["hr", "hrv"], ["bg", "bul"],
        ["sr", "srp"], ["pt-br", "por"], ["pt-pt", "por"],
    ]

    // MARK: - Segment Skip

    /// Resolves the currently skippable segment from the playback-time sink so the UI shows or hides
    /// the skip pill, and fires the opt-in auto-skips.
    func updateSkipSegmentVisibility(time: Double) {
        let resolved = SkipSegmentResolver.active(intro: introSegment, recap: recapSegment, time: time)

        // Skip-lockout: a stale pre-seek tick still inside the segment we just skipped must not revive
        // the pill. A different kind falls through, so a recap chains into its intro at once.
        if let locked = didSkipCurrentSegment, resolved?.kind == locked {
            if activeSkipSegment != nil { setActiveSkipSegment(nil) }
            return
        }

        // Auto-skip on the first tick inside the segment (opt-in), guarded to fire once per kind.
        if let resolved, shouldAutoSkip(resolved) {
            markAutoSkipped(resolved.kind)
            skip(resolved)
            return
        }

        if resolved != activeSkipSegment {
            setActiveSkipSegment(resolved)
        }
    }

    private func shouldAutoSkip(_ segment: ActiveSkipSegment) -> Bool {
        switch segment.kind {
        case .intro: preferences.autoSkipIntro && !didAutoSkipCurrentIntro
        case .recap: preferences.autoSkipRecap && !didAutoSkipCurrentRecap
        }
    }

    private func markAutoSkipped(_ kind: SkipSegmentKind) {
        switch kind {
        case .intro: didAutoSkipCurrentIntro = true
        case .recap: didAutoSkipCurrentRecap = true
        }
    }

    /// Update the state and move focus off the skip button if it just vanished, else the user is stuck on it.
    private func setActiveSkipSegment(_ newValue: ActiveSkipSegment?) {
        activeSkipSegment = newValue
        if newValue == nil && controlsFocus == .skipSegmentButton {
            if !player.audioTracks.isEmpty { controlsFocus = .audioButton }
            else if !subtitleStreams.isEmpty { controlsFocus = .subtitleButton }
            else { controlsFocus = .speedButton }
        }
    }

    /// Jump past the segment currently on offer. Triggered by the skip button and the Select gate.
    func skipActiveSegment() {
        guard let segment = activeSkipSegment else { return }
        skip(segment)
    }

    private func skip(_ segment: ActiveSkipSegment) {
        setActiveSkipSegment(nil)
        didSkipCurrentSegment = segment.kind
        Task { [weak self] in
            // endSeconds is absolute source time; seek(to:) is source-PTS based and applies the clock shift itself.
            await self?.player.seek(to: segment.endSeconds)
            // Clear the lockout after a 500ms settle (absorbs post-seek jitter) so a deliberate
            // backward scrub re-offers the pill; without it the lockout persists the whole episode.
            try? await Task.sleep(for: .milliseconds(500))
            self?.didSkipCurrentSegment = nil
        }
    }

    /// Outro auto-skip (no Skip Outro button), fires once per episode at the outro boundary:
    /// - autoSkipOutro + autoplayNextEpisode + next ready → jump straight to the next episode.
    /// - else → seek to outro.endSeconds and let the regular next-episode flow take over.
    func updateOutroAutoSkip(time: Double) {
        guard let seg = outroSegment,
              preferences.autoSkipOutro,
              !didAutoSkipCurrentOutro else { return }
        guard time >= seg.startSeconds else { return }
        didAutoSkipCurrentOutro = true

        if preferences.autoplayNextEpisode, nextEpisode != nil {
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
        } else {
            Task { [weak self] in await self?.player.seek(to: seg.endSeconds) }
        }
    }

    /// Fetch intro + outro + recap markers once on startup. Safe if the server lacks the endpoint
    /// (empty struct, features stay off).
    func loadEpisodeSegments() async {
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentRecap = false
        didAutoSkipCurrentOutro = false
        didSkipCurrentSegment = nil
        do {
            let segments = try await playbackService.getEpisodeSegments(itemID: item.id)
            introSegment = segments.intro
            outroSegment = segments.outro
            recapSegment = segments.recap
        } catch {
            #if DEBUG
            print("[MediaSegments] Fetch failed: \(error)")
            #endif
            introSegment = nil
            outroSegment = nil
            recapSegment = nil
        }
    }

    /// Apply the playback speed at the given index in `speedOptions`.
    func selectSpeed(index: Int) {
        let clamped = max(0, min(Self.speedOptions.count - 1, index))
        activeSpeedIndex = clamped
        player.setRate(Self.speedOptions[clamped])
    }

    func selectSubtitleTrack(id: Int?, userInitiated: Bool = false) {
        defer { onSubtitleSelectionChanged?() }
        // Sodalite#63 / #65: the user's own pick ends the temporary windows; their selection stands
        // and is never switched off behind their back.
        if userInitiated {
            skipBackSubtitleWindow = nil
            endSystemCaptionWindow(restoringSubtitles: false)
        }
        // #32: the active subtitle changed, so the native rendition selection is stale; re-select on the next
        // PiP/external-display entry (also hides any currently-shown native track so it can't linger from a
        // prior pick).
        resetNativeSubtitleRenderingState()
        setNativeSubtitleRenditionVisible(false)
        // Sodalite#46: only the user's own pick is remembered. Recording an automatic one
        // would bake it in and make later changes to the language settings ineffective.
        if userInitiated, let key = memoryScopeKey {
            // An id we cannot resolve to a stream records nothing: silently storing .off
            // there would remember the opposite of what the user picked.
            if let id {
                if let stream = subtitleStreams.first(where: { $0.index == id }) {
                    trackMemory?.recordSubtitle(.track(TrackSelectionMatcher.subtitleSignature(stream)), for: key)
                }
            } else {
                trackMemory?.recordSubtitle(.off, for: key)
            }
        }
        // Cancel any in-flight transcode-path load so a slow earlier extraction can't overwrite the
        // cues for the track the user just selected (or disabled).
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        guard let id else {
            activeSubtitleIndex = nil
            activeSubtitleCodec = nil
            subtitleCues = []
            deactivateASSRendering()
            player.clearSubtitle()
            // "Off" is when disc-parity forced captions kick in: silently re-feed a forced source.
            applyForcedSubtitleFallback()
            return
        }
        // A user pick supersedes any silent forced fallback; the engine select below overrides it.
        forcedSubtitleFallback = .none
        activeSubtitleIndex = id
        // Drop the secondary if it equals the new primary (a track can't be both lines).
        if activeSecondarySubtitleIndex == id {
            selectSecondarySubtitleTrack(id: nil)
        }
        let stream = subtitleStreams.first(where: { $0.index == id })
        activeSubtitleCodec = stream?.codec?.lowercased()
        let isExternal = stream?.isExternal == true

        if isExternal {
            deactivateASSRendering()
            // AE#88: external streams are engine-registered tracks; the unified select lists them,
            // publishes activeSubtitleTrackIndex, and (load-declared) maps them into the native
            // rendition. Cues land on engine.subtitleCues and the mirror sink picks them up.
            if let engineID = engineTrackID(forExternalStream: stream, jellyfinIndex: id) {
                player.selectSubtitleTrack(index: engineID)
                subtitleCues = []
                // Styled ASS for external .ass/.ssa: wait for the async engine.sidecarASSHeader, then
                // activate the coordinator like the embedded path (AetherEngine#48).
                if (activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"),
                   preferences.styledASSSubtitles {
                    activateSidecarASSWhenHeaderArrives()
                }
            } else {
                player.clearSubtitle()
                subtitleCues = []
            }
        } else if activePlayMethod != .transcode {
            // Embedded stream on direct play/stream: engine streams cues from the main demux loop (text
            // and bitmap codecs alike), no second connection or server extraction.
            player.selectSubtitleTrack(index: id)
            subtitleCues = player.subtitleCues
            // ASS/SSA gets the styled libass path on top (coordinator reassembles raw event cues for
            // swift-ass-renderer); falls back to the stripped-text overlay when the header is missing.
            if (activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"),
               preferences.styledASSSubtitles {
                let engineTrack = player.subtitleTracks.first(where: { $0.id == id })
                // Renderer can arrive async when embedded font attachments need writing; the callback
                // mirrors it then, the direct read below covers the synchronous warm path.
                assCoordinator.onRendererChanged = { [weak self] renderer in
                    self?.assRenderer = renderer
                }
                assCoordinator.activate(header: engineTrack?.assHeader, itemID: item.id)
                assRenderer = assCoordinator.renderer
            } else {
                deactivateASSRendering()
            }
        } else {
            // Transcoded session: HLS rewrites stream indices, so fall back to the legacy server-extracted
            // SRT loader (text codecs only).
            deactivateASSRendering()
            player.clearSubtitle()
            subtitleCues = []
            subtitleLoadTask = Task { await loadSubtitles(streamIndex: id) }
        }

        // Subtitle picked while the video lives in the PiP window (next-episode auto-advance runs the
        // new session's auto-pick through here): the load's deselect pin cleared the native rendition,
        // re-select the one matching this track so the window keeps rendering subtitles (#32, AE#158).
        if player.pictureInPictureActive {
            enterNativeSubtitleRendering()
        }
    }

    /// Sodalite#63: open the temporary subtitle window for a committed backward jump. Consumes the
    /// pending origin either way, so an abandoned or forward commit cannot open one later. A window
    /// that is already open is extended rather than restarted, which is what makes a burst of presses
    /// one window ending where the user actually left.
    func openSkipBackSubtitlesIfNeeded(targetTime: Double) {
        let pendingOrigin = pendingSkipBackOrigin
        pendingSkipBackOrigin = nil

        guard let pendingOrigin else {
            // A commit that is not a backward jump (pan, hold-seek, forward jump) voids the catch-up
            // contract, so it ends an open window here. Leaving it open would hand the closing
            // condition to a playhead that may not reach the origin again for half an hour.
            skipBackBurstOrigin = nil
            endSkipBackSubtitleWindow()
            return
        }
        if var open = skipBackSubtitleWindow {
            let origin = SkipBackSubtitleWindow.mergedOrigin(open.origin, pendingOrigin)
            // Sodalite#65: a burst that walks past the promised 30 s is a rewind, not a catch-up.
            // Switching the subtitles off is the honest answer to "up to 30 seconds"; the burst
            // origin outlives this, so the presses that follow cannot open a fresh window either.
            guard SkipBackSubtitleWindow.withinPromise(origin: origin, landing: targetTime) else {
                endSkipBackSubtitleWindow()
                return
            }
            open.origin = origin
            open.landing = targetTime
            skipBackSubtitleWindow = open
            return
        }
        guard SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: pendingOrigin,
            targetTime: targetTime,
            subtitlesActive: activeSubtitleIndex != nil,
            enabled: preferences.subtitlesOnSkipBack
        ) else { return }

        let audioLanguage = player.audioTracks
            .first(where: { $0.id == player.activeAudioTrackIndex })?.language
        guard let streamIndex = SkipBackSubtitleWindow.resolveTrack(
            streams: subtitleStreams,
            preferredSubtitleLanguage: preferences.preferredSubtitleLanguage,
            audioLanguage: audioLanguage,
            unlabelledCountsAsHeard: isLiveSession
        ) else { return }

        // userInitiated stays false: this is an automatic pick, and recording it would bake a
        // temporary track into the remembered selection (Sodalite#46).
        selectSubtitleTrack(id: streamIndex)
        skipBackSubtitleWindow = SkipBackSubtitleWindow.State(
            origin: pendingOrigin, landing: targetTime, streamIndex: streamIndex)
    }

    /// Close the window once playback has caught up with where the jump started. Driven by the clock
    /// sink rather than a timer, so playback speed and pauses need no handling of their own.
    func closeSkipBackSubtitlesIfReached(time: Double) {
        guard SkipBackSubtitleWindow.shouldClose(state: skipBackSubtitleWindow, playhead: time) else { return }
        endSkipBackSubtitleWindow()
    }

    /// Sodalite#65: the system asked for captions on its own. The engine already took its own
    /// rendition back out, so nothing is on screen; answer the muted-playback case with the app's
    /// own subtitles in the language the system picked. The other two triggers arrive here as well
    /// and are left alone: skip back is `SkipBackSubtitleWindow`, a language mismatch at load is the
    /// preferred-subtitle settings, and both would otherwise switch a second track on top.
    private func handleSystemCaptionRequest(_ request: SystemCaptionRequest) {
        guard systemCaptionWindow == nil else { return }
        // The skip-back trigger fires the same signal, and at a very low volume it would otherwise
        // open a window here that only a volume change can close, i.e. subtitles long past the 30 s
        // the skip-back behaviour promises. That trigger belongs to SkipBackSubtitleWindow.
        if let jump = lastBackwardJumpAt,
           Date().timeIntervalSince(jump) < Self.systemCaptionSkipBackGrace { return }
        let volume = AVAudioSession.sharedInstance().outputVolume
        guard SystemCaptionWindow.shouldOpen(
            subtitlesActive: activeSubtitleIndex != nil,
            volume: volume
        ) else { return }

        let audioLanguage = player.audioTracks
            .first(where: { $0.id == player.activeAudioTrackIndex })?.language
        guard let streamIndex = SystemCaptionWindow.resolveTrack(
            streams: subtitleStreams,
            requestedLanguage: request.language,
            preferredSubtitleLanguage: preferences.preferredSubtitleLanguage,
            preferredLanguage: effectivePreferredAudioLanguage(),
            audioLanguage: audioLanguage,
            unlabelledCountsAsHeard: isLiveSession
        ) else { return }

        // userInitiated stays false: an automatic pick, and recording it would bake a temporary
        // track into the remembered selection (Sodalite#46).
        selectSubtitleTrack(id: streamIndex)
        systemCaptionWindow = SystemCaptionWindow.State(streamIndex: streamIndex)
        LogTap.shared.note(
            "[PlayerVM] system caption request (lang=\(request.language ?? "none"), volume="
            + String(format: "%.2f", volume) + ") -> subtitle stream \(streamIndex)")
    }

    /// The volume is the only signal that the mute is over: the engine deselected the system's own
    /// option when the request arrived, so there is no selection left for the system to change back.
    /// Driven by the player's volume KVO on iOS and by the clock sink everywhere.
    func closeSystemCaptionWindowIfAudible(volume: Float) {
        guard SystemCaptionWindow.shouldClose(state: systemCaptionWindow, volume: volume) else { return }
        endSystemCaptionWindow(restoringSubtitles: true)
    }

    /// `restoringSubtitles` false drops the window without touching the selection, for the callers
    /// that are already changing it (a new session, the user's own pick).
    func endSystemCaptionWindow(restoringSubtitles: Bool) {
        guard let window = systemCaptionWindow else { return }
        systemCaptionWindow = nil
        guard restoringSubtitles else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Only ever switch off the track this window switched on; anything else belongs to
            // someone else, and selecting nil would drop their pick with it.
            guard self.activeSubtitleIndex == window.streamIndex else { return }
            self.selectSubtitleTrack(id: nil)
        }
    }

    /// Sodalite#63 / #65: drop the temporary subtitle windows for a session that is about to start.
    /// Both load paths run it, and that is the point: the live branch returns before the shared block
    /// below, so a window opened before a channel zap used to survive into the next channel. It then
    /// measures a landing on a clock that restarted, fails the 30 s promise on the first skip back
    /// there, and switches the new channel's subtitles off out of nowhere (engine stream indices are
    /// small and repeat across channels, so the "only switch off my own track" guard does not catch
    /// it). Nothing is deselected here: the incoming session resolves its own tracks right after.
    func resetTemporarySubtitleWindows() {
        pendingSkipBackOrigin = nil
        skipBackBurstOrigin = nil
        skipBackSubtitleWindow = nil
        lastBackwardJumpAt = nil
        endSystemCaptionWindow(restoringSubtitles: false)
    }

    private func endSkipBackSubtitleWindow() {
        guard let window = skipBackSubtitleWindow else { return }
        // Drop the window synchronously so the next clock tick cannot queue a second teardown,
        // then do the work itself one main-actor turn later. The identical teardown does not stutter
        // when a manual pick triggers it; inside the 10 Hz tick it shares a block with
        // scrubPreview.warm, which spins up its own demuxer while this one closes a side demuxer.
        skipBackSubtitleWindow = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Only ever switch off the track this window switched on; anything else belongs to
            // someone else, and selecting nil would drop their pick with it.
            guard self.activeSubtitleIndex == window.streamIndex else { return }
            self.selectSubtitleTrack(id: nil)
        }
    }

    /// Select the SECONDARY companion subtitle track (issue #47). Text-only, session-only: no styled-ASS,
    /// no transcode fallback (only direct play / sidecar offer a secondary), no persistence.
    func selectSecondarySubtitleTrack(id: Int?) {
        guard let id else {
            activeSecondarySubtitleIndex = nil
            secondarySubtitleCues = []
            player.clearSecondarySubtitle()
            return
        }
        activeSecondarySubtitleIndex = id
        let stream = subtitleStreams.first(where: { $0.index == id })
        let isExternal = stream?.isExternal == true

        if isExternal {
            if let engineID = engineTrackID(forExternalStream: stream, jellyfinIndex: id) {
                player.selectSecondarySubtitleTrack(index: engineID)
                secondarySubtitleCues = []
            } else {
                player.clearSecondarySubtitle()
                secondarySubtitleCues = []
                activeSecondarySubtitleIndex = nil
            }
        } else if activePlayMethod != .transcode {
            player.selectSecondarySubtitleTrack(index: id)
            secondarySubtitleCues = player.secondarySubtitleCues
        } else {
            // Transcoded session: no secondary path in v1.
            player.clearSecondarySubtitle()
            secondarySubtitleCues = []
            activeSecondarySubtitleIndex = nil
        }
    }

    /// AE#88: engine track id for an external Jellyfin stream: the load-time map, else register now
    /// (post-download tracks from the subtitle search; overlay-only until the next load, matching
    /// the engine's hybrid rule).
    private func engineTrackID(forExternalStream stream: MediaStream?, jellyfinIndex id: Int) -> Int? {
        if let mapped = externalEngineTrackIDs[id] { return mapped }
        guard let url = playbackService.buildSubtitleURL(
            itemID: item.id, mediaSourceID: mediaSourceID,
            streamIndex: id, format: stream?.codec ?? "srt") else { return nil }
        let info = player.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: stream?.title ?? stream?.displayTitle,
            language: stream?.language, isForced: stream?.isForced == true,
            formatHint: stream?.codec))
        externalEngineTrackIDs[id] = info.id
        return info.id
    }

    /// Activate styled ASS for an external sidecar once the engine publishes its (async) header:
    /// subscribe to `engine.$sidecarASSHeader` and activate on the first non-nil value (AetherEngine#48).
    /// No header → coordinator never activates and the overlay's stripper handles the raw lines.
    private func activateSidecarASSWhenHeaderArrives() {
        sidecarASSHeaderCancellable?.cancel()
        assCoordinator.onRendererChanged = { [weak self] renderer in
            self?.assRenderer = renderer
        }
        sidecarASSHeaderCancellable = player.$sidecarASSHeader
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .first()
            .sink { [weak self] header in
                guard let self else { return }
                self.assCoordinator.activate(header: header, itemID: self.item.id)
                self.assRenderer = self.assCoordinator.renderer
            }
    }

    /// Tear down the styled ASS bridge and clear its observable mirror; safe when already inactive.
    /// Internal so the cross-file NextEpisode extension can call it on bypass-teardown transitions.
    func deactivateASSRendering() {
        sidecarASSHeaderCancellable?.cancel()
        sidecarASSHeaderCancellable = nil
        assCoordinator.deactivate()
        assRenderer = nil
    }

    private static let subtitleLog = Logger(
        subsystem: "de.superuser404.Sodalite",
        category: "Subtitles"
    )

    private func loadSubtitles(streamIndex: Int) async {
        let stream = subtitleStreams.first(where: { $0.index == streamIndex })
        Self.subtitleLog.notice(
            "loadSubtitles streamIndex=\(streamIndex, privacy: .public) codec=\(stream?.codec ?? "nil", privacy: .public) lang=\(stream?.language ?? "nil", privacy: .public)"
        )

        guard let url = playbackService.buildSubtitleURL(
            itemID: item.id,
            mediaSourceID: mediaSourceID,
            streamIndex: streamIndex,
            format: "srt"
        ) else {
            Self.subtitleLog.notice("→ failed to build URL")
            return
        }

        // First hit can take seconds (Jellyfin lazy-extracts the sub via FFmpeg, nothing cached yet).
        // Two attempts with a 120s budget cover both the slow extraction and a transient.
        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) HTTP \(http.statusCode, privacy: .public)")
                    if attempt == 2 { return }
                    continue
                }
                guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) empty payload")
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let cues = SRTParser.parse(content)
                if cues.isEmpty {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) parsed 0 cues from \(content.count, privacy: .public) bytes")
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // A slow extraction may finish after the user switched/disabled the track; only the
                // still-selected stream may write, so a stale load is a no-op.
                guard !Task.isCancelled, activeSubtitleIndex == streamIndex else {
                    Self.subtitleLog.notice("→ stale load for \(streamIndex, privacy: .public) dropped (active=\(self.activeSubtitleIndex ?? -1, privacy: .public))")
                    return
                }
                subtitleCues = cues
                Self.subtitleLog.notice("→ loaded \(cues.count, privacy: .public) cues on attempt \(attempt, privacy: .public)")
                return
            } catch {
                Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == 2 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Helpers

    func showControlsTemporarily() {
        showControls = true
        scheduleControlsHide()
    }

    #if os(iOS)
    enum PlayerHUDKind: Equatable { case brightness, volume, skipForward, skipBackward }

    /// Transient touch HUD (brightness/volume swipe, skip ripple); the overlay observes hudKind.
    var hudKind: PlayerHUDKind?
    var hudLevel: Double = 0
    /// The last shown kind, kept while the HUD is hidden. The overlay is permanently mounted and falls
    /// back to this when hudKind is nil, so it fades out on the same glyph it showed and never reveals
    /// an unrelated icon (the skip symbol) on the way in or out.
    var lastHudKind: PlayerHUDKind = .volume
    @ObservationIgnored private var hudHideTask: Task<Void, Never>?

    func flashHUD(_ kind: PlayerHUDKind, level: Double = 0) {
        hudKind = kind
        lastHudKind = kind
        hudLevel = level
        hudHideTask?.cancel()
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.hudKind = nil
        }
    }

    /// Touch skip (double-tap sides). seekJump sets the scrub target and arms a short coalescing idle;
    /// on touch we commit right there, since a tap has no burst to wait for.
    func skip(by seconds: Double) {
        seekJump(seconds: seconds)
        commitScrub()
        flashHUD(seconds >= 0 ? .skipForward : .skipBackward)
    }

    /// Same commit-immediately rule for the iPad keyboard's arrow tap, at the configured interval.
    /// The HUD it flashes is also the only feedback there is, since the AVKit chrome is hidden.
    func skipByConfiguredInterval(direction: Int) {
        skip(by: Double((direction < 0 ? -1 : 1) * preferences.skipIntervalSeconds))
    }

    func setBrightness(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen.brightness = clamped
        flashHUD(.brightness, level: Double(clamped))
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        PlayerSystemVolume.set(clamped)
        flashHUD(.volume, level: Double(clamped))
    }

    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?

    /// Mirror the system volume overlay with our own HUD on hardware volume-button presses, but only once
    /// we have taken over the native overlay (PlayerSystemVolume.isActive, i.e. the hidden MPVolumeView is
    /// parked, which happens at first `.playing` or on a volume swipe). While the video is still loading,
    /// or anywhere outside the player, the host is not parked, so the native iOS overlay shows and this
    /// stays silent. Gating on isActive also swallows the activation-time settle callback without a timer.
    func startVolumeObservation() {
        volumeObservation?.invalidate()
        // @Sendable so the KVO callback is nonisolated (KVO fires off the main actor); it hops back via Task.
        let handler: @Sendable (AVAudioSession, NSKeyValueObservedChange<Float>) -> Void = { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                guard let self else { return }
                // Sodalite#65: the volume coming back up is what ends muted-playback subtitles, and
                // it must not depend on whether our own volume HUD has taken over yet.
                self.closeSystemCaptionWindowIfAudible(volume: newValue)
                guard PlayerSystemVolume.isActive else { return }
                self.flashHUD(.volume, level: Double(newValue))
            }
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new], changeHandler: handler)
    }

    func stopVolumeObservation() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        // Restore the native volume overlay for the rest of the app now that the player is gone.
        PlayerSystemVolume.deactivate()
    }
    #endif

    func hideControls() {
        showControls = false
        controlsFocus = .progressBar
        trackDropdown = .none
    }

    /// Engage the iOS child lock: disable input, tear down any open chrome, cancel the auto-hide.
    func lockInput() {
        isInputLocked = true
        cancelControlsHide()
        showControls = false
        controlsFocus = .progressBar
        trackDropdown = .none
    }

    /// Release the iOS child lock.
    func unlockInput() {
        isInputLocked = false
    }

    func scheduleControlsHide() {
        controlsTimer?.cancel()
        guard isPlaying else { return }
        controlsTimer = Task {
            try? await Task.sleep(for: TransportAutoHide.idleDelay)
            guard !Task.isCancelled else { return }
            hideControlsIfPlaying()
        }
    }

    /// The auto-hide's liveness check, asked at FIRE time (see `TransportAutoHide`). Explicit
    /// dismissals (Menu, PiP handoff, child lock) keep calling `hideControls()` directly.
    private func hideControlsIfPlaying() {
        guard TransportAutoHide.hides(isPlaying: isPlaying) else { return }
        hideControls()
    }

    /// Pause the controls auto-hide while the user is actively in a touch menu; re-arm via scheduleControlsHide().
    func cancelControlsHide() {
        controlsTimer?.cancel()
    }

    // MARK: - Transport control activation (shared by the tvOS press dispatch and iOS taps)

    /// Runs the action for a focused/tapped transport control. tvOS calls this from selectPressed;
    /// iOS calls it directly from the SwiftUI track buttons.
    func activateControl(_ focus: ControlsFocus) {
        switch focus {
        case .restartButton: restartFromBeginning()
        case .skipSegmentButton: skipActiveSegment()
        case .nextEpisodeButton: Task { await playNextEpisode() }
        case .chapterButton: openChapterDropdown()
        case .episodeButton: openEpisodeDropdown()
        case .audioButton: openAudioDropdown()
        case .subtitleButton: openSubtitleDropdown()
        case .speedButton: openSpeedDropdown()
        case .pictureButton: openPictureDropdown()
        case .pipButton: requestPictureInPicture()
        case .infoButton:
            showStatsOverlay.toggle()
            scheduleControlsHide()
        case .returnToLiveButton:
            returnToLiveEdge()
            controlsFocus = .progressBar
            scheduleControlsHide()
        default:
            break
        }
    }

    func openAudioDropdown() {
        let tracks = displayAudioTracks
        guard !tracks.isEmpty else { return }
        controlsTimer?.cancel()
        let currentIdx = tracks.firstIndex(where: { $0.id == activeAudioIndex }) ?? 0
        trackDropdown = .audio(highlighted: currentIdx)
    }

    func openSubtitleDropdown() {
        controlsTimer?.cancel()
        trackDropdown = .subtitle(
            highlighted: SubtitleMenuLayout.highlightIndex(forActive: activeSubtitleIndex,
                                                           in: subtitleMenuRows)
        )
    }

    func openSpeedDropdown() {
        controlsTimer?.cancel()
        trackDropdown = .speed(highlighted: activeSpeedIndex)
    }

    func openPictureDropdown() {
        controlsTimer?.cancel()
        let modes = PlaybackPreferences.PictureMode.allCases
        let currentIdx = modes.firstIndex(of: pictureMode) ?? 0
        trackDropdown = .picture(highlighted: currentIdx)
    }

    func openEpisodeDropdown() {
        guard seasonEpisodes.count > 1 else { return }
        controlsTimer?.cancel()
        let currentIdx = seasonEpisodes.firstIndex(where: { $0.id == item.id }) ?? 0
        trackDropdown = .episode(highlighted: currentIdx)
    }

    /// Index into `chapters` of the chapter containing the frame on screen: the last one starting at
    /// or before it. nil only when there are no chapters. Both pickers open on it and iOS marks it.
    ///
    /// sourceTime, not currentTime: chapter marks sit on the absolute source timeline, and during a
    /// seek `sourceTime` still names the frame the viewer is looking at.
    var activeChapterIndex: Int? {
        guard !chapters.isEmpty else { return nil }
        let nowSeconds = player.sourceTime
        var idx = 0
        for (i, chapter) in chapters.enumerated() {
            if chapter.startSeconds <= nowSeconds + 0.001 { idx = i } else { break }
        }
        return idx
    }

    func openChapterDropdown() {
        guard chapters.count > 1 else { return }
        controlsTimer?.cancel()
        trackDropdown = .chapter(highlighted: activeChapterIndex ?? 0)
    }

    func confirmDropdownSelection() {
        switch trackDropdown {
        case .chapter(let idx):
            selectChapter(at: idx)
            trackDropdown = .none
            scheduleControlsHide()
        case .episode(let idx):
            trackDropdown = .none
            Task { await selectEpisode(at: idx) }
        case .audio(let idx):
            let tracks = displayAudioTracks
            if idx < tracks.count { selectAudioTrack(id: tracks[idx].id, userInitiated: true) }
            trackDropdown = .none
            scheduleControlsHide()
        case .subtitle(let idx):
            let rows = subtitleMenuRows
            guard idx >= 0, idx < rows.count else { return }
            switch rows[idx] {
            case .secondaryHeader:
                trackDropdown = .secondarySubtitle(highlighted: 0)
            case .off:
                selectSubtitleTrack(id: nil, userInitiated: true)
                trackDropdown = .none
                scheduleControlsHide()
            case .track(let streamIndex):
                selectSubtitleTrack(id: streamIndex, userInitiated: true)
                trackDropdown = .none
                scheduleControlsHide()
            case .searchOnline:
                trackDropdown = .none
                presentSubtitleSearch()
            }
        case .secondarySubtitle(let idx):
            let candidates = secondarySubtitleCandidates
            if idx == 0 {
                trackDropdown = .subtitle(highlighted: 0)
            } else if idx == 1 {
                selectSecondarySubtitleTrack(id: nil)
                trackDropdown = .none
                scheduleControlsHide()
            } else {
                let candidateIdx = idx - 2
                if candidateIdx < candidates.count { selectSecondarySubtitleTrack(id: candidates[candidateIdx].index) }
                trackDropdown = .none
                scheduleControlsHide()
            }
        case .speed(let idx):
            selectSpeed(index: idx)
            trackDropdown = .none
            scheduleControlsHide()
        case .picture(let idx):
            let modes = PlaybackPreferences.PictureMode.allCases
            if modes.indices.contains(idx) { selectPictureMode(modes[idx]) }
            trackDropdown = .none
            scheduleControlsHide()
        case .none:
            break
        }
    }

    /// iOS: a tapped dropdown row re-points the open dropdown's highlight, then confirms.
    func selectDropdownItem(at index: Int) {
        switch trackDropdown {
        case .audio: trackDropdown = .audio(highlighted: index)
        case .subtitle: trackDropdown = .subtitle(highlighted: index)
        case .secondarySubtitle: trackDropdown = .secondarySubtitle(highlighted: index)
        case .speed: trackDropdown = .speed(highlighted: index)
        case .picture: trackDropdown = .picture(highlighted: index)
        case .episode: trackDropdown = .episode(highlighted: index)
        case .chapter: trackDropdown = .chapter(highlighted: index)
        case .none: return
        }
        confirmDropdownSelection()
    }

    static func bufferedProgressValue(bufferedPosition: Double, duration: Double, isLive: Bool) -> Float {
        guard !isLive, duration > 0 else { return 0 }
        return Float(min(max(bufferedPosition / duration, 0), 1))
    }

    func formatSeconds(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

enum PlayerEngineError: LocalizedError {
    case noSource
    case noURL
    /// A live channel refused before the engine was asked, because every audio track the server named
    /// is a format nothing on this device decodes (#100). The payload is the format's display name.
    case liveAudioUnsupported(codec: String)

    var errorDescription: String? {
        switch self {
        case .noSource:
            String(
                localized: "player.error.noSource",
                defaultValue: "The server didn't return any media source for this item."
            )
        case .noURL:
            String(
                localized: "player.error.noURL",
                defaultValue: "Couldn't build a stream URL for this item."
            )
        case .liveAudioUnsupported(let codec):
            String(
                format: String(
                    localized: "player.error.liveAudioUnsupported.body",
                    defaultValue: "This channel's audio is %@, which no decoder on this device supports. Trying again will not help."
                ),
                codec
            )
        }
    }
}
