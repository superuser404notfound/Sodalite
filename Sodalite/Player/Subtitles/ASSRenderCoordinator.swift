import Foundation
import Combine
import AetherEngine
import SwiftAssRenderer

/// Drives swift-ass-renderer from AetherEngine's data surface for
/// styled ASS/SSA subtitle tracks (AetherEngine#30 host contract):
///
///   raw paced event cues (`preserveASSMarkup`) + `TrackInfo.assHeader`
///   -> `ASSScriptBuilder` -> batched `reloadTrack(content:)`
///   `engine.clock.$sourceTime` -> `setTimeOffset`
///   `engine.fontAttachments` -> font directory -> `FontConfig`
///
/// One instance per session, owned by `PlayerViewModel`; inactive until an ASS/SSA track selected.
@MainActor
final class ASSRenderCoordinator {

    /// Non-nil exactly while an ASS track is active AND the renderer initialized; else the
    /// overlay falls back to the text path.
    private(set) var renderer: AssSubtitlesRenderer?

    /// Fires immediately BEFORE every `reloadTrack` so the overlay can suppress the renderer's
    /// transient re-parse nil deterministically (a pure time-based window loses the race when
    /// re-parse + font matching runs long and the sub blinks mid-line).
    let reloadSignal = PassthroughSubject<Void, Never>()

    private let player: AetherEngine
    private var builder: ASSScriptBuilder?
    private var cancellables = Set<AnyCancellable>()
    private var lastReloadAt = Date.distantPast
    private var pendingEvents = false
    /// Earliest start among events added since the last reload; drives the imminent-flush bypass.
    private var earliestPendingStart = Double.infinity
    /// Last clock-sink offset (source-PTS seconds), compared against `earliestPendingStart`.
    private var lastOffset: Double = 0
    /// Batch window before reparsing the whole script. Per-cue reload (1-2/s) is pointless churn;
    /// in steady-state streaming the side demuxer runs ~90 s ahead so new events are far off.
    private let reloadInterval: TimeInterval = 5
    /// Imminent-flush bypass: after a seek/mid-dialogue activation the catch-up burst delivers
    /// events within seconds of the playhead; holding them the full window drops a running
    /// dialogue's continuation lines (field repro: subs "ending too early" right after scrubs).
    /// A pending event starting inside this lead flushes immediately.
    private let imminentLeadSeconds: Double = 10
    /// Spacing even for imminent flushes so the post-seek catch-up burst (~1-2 s) coalesces into
    /// a few reloads instead of one libass parse per cue.
    private let minImminentSpacing: TimeInterval = 0.25

    init(player: AetherEngine) {
        self.player = player
    }

    /// The viewer's subtitle delay (global plus per title). Positive draws later, so the renderer
    /// is asked for an earlier script time. Read on every clock tick, so a change lands at once.
    var delaySeconds: () -> Double = { 0 }

    /// Script time the renderer draws at; the overlay queries the same time for its hide logic.
    var scriptTime: Double { lastOffset - delaySeconds() }

    /// Re-apply the delay without waiting for the clock, which does not tick while paused.
    func refreshTimeOffset() {
        renderer?.setTimeOffset(scriptTime)
    }

    /// Fired when the renderer becomes available asynchronously (first activation with unwritten
    /// fonts) or is torn down; PlayerViewModel mirrors it onto its observable surface.
    var onRendererChanged: ((AssSubtitlesRenderer?) -> Void)?
    /// Guards async font-write completion against a deactivate/re-activate during the writes.
    private var activationGeneration = 0

    /// Activate for the selected embedded track (`header` = track's `assHeader`). Bails (renderer
    /// stays nil, caller keeps the text path) when the header is missing or setup fails.
    /// Fonts are written off-main (anime MKVs embed dozens of 5-20 MB CJK faces); when all files
    /// already exist the renderer installs synchronously so `activate(...); renderer` still works.
    func activate(header: String?, itemID: String) {
        deactivate()
        guard let header, !header.isEmpty else { return }
        activationGeneration += 1
        let generation = activationGeneration
        let fontsDir = ASSFontCache.directory(itemID: itemID)
        ASSFontCache.prune(keeping: fontsDir)
        let fonts = player.fontAttachments
        if Self.allFontsPresent(fonts, in: fontsDir) {
            installRenderer(fontsDir: fontsDir)
        } else {
            Task.detached(priority: .userInitiated) { [weak self] in
                Self.writeFontAttachments(fonts, to: fontsDir)
                await MainActor.run {
                    guard let self, self.activationGeneration == generation else { return }
                    self.installRenderer(fontsDir: fontsDir)
                }
            }
        }
        let builder = ASSScriptBuilder(header: header)
        self.builder = builder

        // Cue sink: accumulate raw event lines, reload batched. Post-seek re-emits (cue array
        // resets) are absorbed by the builder's ReadOrder dedupe.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in self?.consume(cues: cues) }
            .store(in: &cancellables)

        // Clock sink: cue times and sourceTime share the source-PTS coordinate (no conversion).
        // Doubles as trailing-batch flush, since the cue sink only runs on cue-array emissions
        // and a batch landing in the window with no later emission (EOF tail) would never flush.
        player.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.lastOffset = t
                self.renderer?.setTimeOffset(self.scriptTime)
                self.flushPendingEventsIfDue()
            }
            .store(in: &cancellables)
    }

    func deactivate() {
        activationGeneration += 1
        cancellables.removeAll()
        renderer?.freeTrack()
        renderer = nil
        builder = nil
        // The offered set is keyed against THIS builder's contents; a new track builds a new one.
        // `activate` deactivates first, so clearing here covers both directions.
        offered.reset()
        pendingEvents = false
        earliestPendingStart = .infinity
        lastReloadAt = .distantPast
    }

    private func installRenderer(fontsDir: URL) {
        let config = FontConfig(fontsPath: fontsDir, fontProvider: .coreText)
        let renderer = AssSubtitlesRenderer(fontConfig: config)
        self.renderer = renderer
        onRendererChanged?(renderer)
        // Surface events that arrived in the builder while fonts were being written.
        flushPendingEventsIfDue()
    }

    /// Which cues have already been handed to the builder, so a publication carrying the whole
    /// cumulative array only pays for the new ones (AetherEngine#271).
    ///
    /// `ASSScriptBuilder.add` is not cheap per cue: it splits the raw event, splits its nine
    /// fields, materializes a `start|end|line` dedupe key and hashes it. The engine publishes a
    /// cumulative snapshot, which cannot say which of its elements are new, so this sink saw every
    /// retained cue again on every publication and rebuilt all those keys to learn that nothing
    /// changed. On a typeset track that is thousands of string builds per publication.
    ///
    /// The engine's retained store stamps every cue with a session-monotonic id it never reuses,
    /// so an (id, endTime) pair already offered cannot describe a different event. `endTime` is
    /// part of the key because a retained cue can be closed in place (AetherEngine#107 teletext
    /// page semantics); such a cue is offered again, exactly as before this filter existed.
    struct OfferedCues {
        private struct Key: Hashable {
            let id: Int
            let endTime: Double
        }
        private var seen: Set<Key> = []

        /// True the first time this exact cue is seen; false on every later publication of it.
        mutating func take(_ cue: SubtitleCue) -> Bool {
            seen.insert(Key(id: cue.id, endTime: cue.endTime)).inserted
        }

        mutating func reset() {
            seen.removeAll(keepingCapacity: false)
        }
    }

    private var offered = OfferedCues()

    private func consume(cues: [SubtitleCue]) {
        guard let builder else { return }
        var addedAny = false
        for cue in cues {
            guard case .text(let raw) = cue.body, offered.take(cue) else { continue }
            if builder.add(rawEventText: raw, start: cue.startTime, end: cue.endTime) {
                addedAny = true
                earliestPendingStart = min(earliestPendingStart, cue.startTime)
            }
        }
        if addedAny { pendingEvents = true }
        flushPendingEventsIfDue()
    }

    /// Reload the track when events are waiting and either the batch window elapsed or a pending
    /// event is imminent (within `imminentLeadSeconds`). Called from the cue sink and clock sink.
    /// `lastReloadAt` starts `.distantPast` so the first batch always passes the interval check.
    private func flushPendingEventsIfDue() {
        guard pendingEvents, let builder, let renderer else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReloadAt)
        let imminent = earliestPendingStart <= lastOffset + imminentLeadSeconds
        let due = imminent ? elapsed >= minImminentSpacing : elapsed >= reloadInterval
        guard due else { return }
        lastReloadAt = now
        pendingEvents = false
        earliestPendingStart = .infinity
        reloadSignal.send()
        renderer.reloadTrack(content: builder.script())
    }

    // MARK: - Fonts

    private nonisolated static func allFontsPresent(_ fonts: [FontAttachment], in dir: URL) -> Bool {
        fonts.allSatisfy { font in
            let safeName = (font.filename as NSString).lastPathComponent
            guard !safeName.isEmpty else { return true }
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(safeName).path)
        }
    }

    private nonisolated static func writeFontAttachments(_ fonts: [FontAttachment], to dir: URL) {
        for font in fonts {
            // lastPathComponent so a hostile container filename can't escape the cache dir.
            let safeName = (font.filename as NSString).lastPathComponent
            guard !safeName.isEmpty else { continue }
            let url = dir.appendingPathComponent(safeName)
            if !FileManager.default.fileExists(atPath: url.path) {
                // Atomic so a crash mid-write can't leave a truncated font the exists-check
                // above would then treat as complete forever.
                try? font.data.write(to: url, options: .atomic)
            }
        }
    }
}
