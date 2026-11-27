import Foundation
import Combine
import AetherEngine
import SwiftAssRenderer
import Synchronization

/// Drives swift-ass-renderer from AetherEngine's data surface for
/// styled ASS/SSA subtitle tracks (AetherEngine#30 host contract):
///
///   raw paced event cues (`preserveASSMarkup`) + `TrackInfo.assHeader`
///   -> `ASSScriptBuilder` -> batched `reloadTrack(content:)`
///   `engine.clock.$sourceTime` -> `setTimeOffset`
///   `engine.$fontAttachments` -> font directory -> `FontConfig`
///
/// One instance per session, owned by `PlayerViewModel`; inactive until an ASS/SSA track selected.
@MainActor
final class ASSRenderCoordinator {

    /// Non-nil exactly while an ASS track is active AND the renderer initialized; else the
    /// overlay falls back to the text path.
    private(set) var renderer: AssSubtitlesRenderer?

    enum ReloadPhase: Sendable { case began, landed }

    /// `.began` fires immediately BEFORE every `reloadTrack` so the overlay can suppress the
    /// renderer's transient re-parse nil; `.landed` fires once the renderer's work queue has parsed
    /// the new script. The overlay holds the visible line until then instead of guessing with a
    /// timer: a typeset script takes longer than any fixed window to parse on an Apple TV, and a
    /// hide at a window's end while the track was still unloaded lost the line for good, because
    /// libass then reports the identical re-render as unchanged and never republishes it (#234).
    let reloadSignal = PassthroughSubject<ReloadPhase, Never>()

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
    /// Events starting further out than this wait in the builder. Every reload reparses the whole
    /// growing script (and swift-ass-renderer 1.3.2 never frees the track it replaces), so a 5 s
    /// cadence on a heavily typeset track meant a full parse every 5 s for lines a minute away.
    /// The clock sink re-checks on every tick, so a waiting event still loads well before it shows.
    private let reloadLeadSeconds: Double = 30
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
    /// Moves with every renderer built, so a glyph failure only drops the renderer that raised it.
    /// Since swift-ass-renderer 1.3.2 each library logs to its own renderer's output, so a last
    /// render still running on a replaced renderer's queue counts against that one and lands here
    /// with a stale generation.
    private var rendererGeneration = 0

    /// Activate for the selected embedded track (`header` = track's `assHeader`). Bails (renderer
    /// stays nil, caller keeps the text path) when the header is missing or setup fails.
    /// Fonts are written off-main (anime MKVs embed dozens of 5-20 MB CJK faces); when all files
    /// already exist the renderer installs synchronously so `activate(...); renderer` still works.
    /// The engine reads a Matroska file's fonts after the first frame (AE#1129), so an activation at
    /// load usually sees none yet: the renderer starts on whatever the item's cache holds and is
    /// rebuilt once the list lands with fonts the cache lacks.
    func activate(header: String?, itemID: String) {
        deactivate()
        guard let header, !header.isEmpty else { return }
        activationGeneration += 1
        let generation = activationGeneration
        let fontsDir = ASSFontCache.directory(itemID: itemID)
        ASSFontCache.prune(keeping: fontsDir)
        let fonts = player.fontAttachments
        if Self.allFontsPresent(fonts, in: fontsDir) {
            installRenderer(fontsDir: fontsDir, fullScript: false)
        } else {
            Task.detached(priority: .userInitiated) { [weak self] in
                Self.writeFontAttachments(fonts, to: fontsDir)
                await MainActor.run {
                    guard let self, self.activationGeneration == generation else { return }
                    self.installRenderer(fontsDir: fontsDir, fullScript: false)
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

        // Fonts that land after the activation (AE#1129). The current value was handled above.
        player.$fontAttachments
            .dropFirst()
            .filter { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fonts in self?.fontsDidArrive(fonts, fontsDir: fontsDir, generation: generation) }
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

    private func fontsDidArrive(_ fonts: [FontAttachment], fontsDir: URL, generation: Int) {
        guard activationGeneration == generation,
              !Self.allFontsPresent(fonts, in: fontsDir) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            Self.writeFontAttachments(fonts, to: fontsDir)
            await MainActor.run {
                guard let self, self.activationGeneration == generation else { return }
                self.reinstallRenderer(fontsDir: fontsDir)
            }
        }
    }

    /// libass reads its font directory when the renderer is built, so new fonts need a new one. It
    /// starts without a track, so the whole script goes in at once instead of waiting for a batch.
    private func reinstallRenderer(fontsDir: URL) {
        installRenderer(fontsDir: fontsDir, fullScript: true)
    }

    private func installRenderer(fontsDir: URL, fullScript: Bool) {
        // Two font writes can finish in either order, so a renderer may already be up. It is
        // replaced like a reinstall, or it would keep its track and keep rendering.
        var fullScript = fullScript
        if let previous = renderer {
            previous.freeTrack()
            fullScript = true
        }
        let config = FontConfig(fontsPath: fontsDir, fontProvider: .coreText)
        rendererGeneration += 1
        let generation = rendererGeneration
        // A custom output hears warnings in Release too. libass substituting a requested family
        // is normal, so only characters it could not draw at all count (`ASSFontFallback`).
        let glyphFailures = ASSGlyphFailures()
        let renderer = AssSubtitlesRenderer(fontConfig: config, logOutput: .custom { [weak self] message in
            #if DEBUG
            if message.level != .verbose { print(message.message) }
            #else
            if message.level == .fatal { print(message.message) }
            #endif
            guard glyphFailures.take(message: message.message) else { return }
            Task { @MainActor [weak self] in
                self?.handleFontFailure(message.message, generation: generation)
            }
        })
        self.renderer = renderer
        // Paused, the clock does not tick, so without this the new renderer would sit at 0.
        renderer.setTimeOffset(scriptTime)
        onRendererChanged?(renderer)
        if fullScript, builder != nil {
            pendingEvents = true
            earliestPendingStart = lastOffset
            lastReloadAt = .distantPast
        }
        // Surface events that arrived in the builder while fonts were being written.
        flushPendingEventsIfDue()
    }

    private func handleFontFailure(_ message: String, generation: Int) {
        guard generation == rendererGeneration, renderer != nil else { return }
        // Publishing nil switches the overlay to its ASS-to-plain-text path. The raw cues and the
        // saved preference stay, and so does the activation. The builder keeps collecting events
        // and the font sink stays up, because the engine reads a Matroska file's fonts after the
        // first frame (AE#1129) and the face that has these characters may be one of them. When
        // it lands, `reinstallRenderer` brings styling back with the whole script.
        LogTap.shared.note("[Subtitles] styled ASS shows plain text, libass could not draw \(ASSFontFallback.threshold) characters, last: \(message)")
        renderer?.freeTrack()
        renderer = nil
        onRendererChanged?(nil)
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

    /// Reload the track when a pending event comes within `reloadLeadSeconds` of the playhead and
    /// the spacing for its distance has passed. Called from the cue sink and clock sink.
    /// `lastReloadAt` starts `.distantPast` so the first batch always passes the interval check.
    private func flushPendingEventsIfDue() {
        guard pendingEvents, let builder, let renderer else { return }
        let now = Date()
        guard Self.reloadIsDue(earliestPendingStart: earliestPendingStart, playhead: lastOffset,
                               sinceLastReload: now.timeIntervalSince(lastReloadAt),
                               imminentLead: imminentLeadSeconds, reloadLead: reloadLeadSeconds,
                               imminentSpacing: minImminentSpacing, batchSpacing: reloadInterval)
        else { return }
        lastReloadAt = now
        pendingEvents = false
        earliestPendingStart = .infinity
        reloadSignal.send(.began)
        renderer.reloadTrack(content: builder.script())
        // Queued behind the parse on the renderer's serial work queue, so the completion marks
        // the moment the new track is in place. Two main hops, like the frame publisher's.
        renderer.loadFrame(offset: scriptTime) { [weak self] _ in
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.reloadSignal.send(.landed) }
                }
            }
        }
    }

    nonisolated static func reloadIsDue(earliestPendingStart: Double, playhead: Double,
                                        sinceLastReload: TimeInterval, imminentLead: Double,
                                        reloadLead: Double, imminentSpacing: TimeInterval,
                                        batchSpacing: TimeInterval) -> Bool {
        let lead = earliestPendingStart - playhead
        if lead <= imminentLead { return sinceLastReload >= imminentSpacing }
        if lead <= reloadLead { return sinceLastReload >= batchSpacing }
        return false
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

/// When styled ASS gives up. libass substituting a missing family is fine, and so is the first
/// "Glyph ... not found, selecting one more font" line, which a fallback face usually resolves.
/// What counts is a character it could not draw with any face. A few such characters (a PUA sign
/// glyph, a symbol no font has) are not worth the typesetting of the whole track, so the switch
/// waits for `threshold` distinct ones over the renderer's life. One or two Chinese lines next to
/// English reach that at once.
nonisolated struct ASSFontFallback {
    static let threshold = 5
    private var missing: Set<UInt32> = []
    private var fired = false

    /// True exactly once, for the message that brings the count of distinct characters libass
    /// could not draw to `threshold`.
    mutating func take(message: String) -> Bool {
        guard !fired, let codepoint = Self.unrenderableCodepoint(message) else { return false }
        missing.insert(codepoint)
        guard missing.count >= Self.threshold else { return false }
        fired = true
        return true
    }

    /// The character from one of libass 1.4's two terminal messages (`ass_fontselect.c`,
    /// `ass_font.c`), nil for anything else. A generic "font not found" is not one of them,
    /// another attached or installed face may still have the character.
    static func unrenderableCodepoint(_ message: String) -> UInt32? {
        let markers = ["fontselect: failed to find any fallback with glyph 0x", "Glyph 0x"]
        for marker in markers {
            guard let start = message.range(of: marker) else { continue }
            let rest = message[start.upperBound...]
            if marker == "Glyph 0x", !rest.contains(" not found in font for (") { continue }
            let hex = rest.prefix { $0.isHexDigit }
            if let codepoint = UInt32(hex, radix: 16) { return codepoint }
        }
        return nil
    }
}

/// One renderer's `ASSFontFallback`. libass logs from the renderer's work queue, so the count
/// takes a lock there and only the one message that crosses the threshold hops to the main actor.
nonisolated final class ASSGlyphFailures: Sendable {
    private let state = Mutex(ASSFontFallback())

    func take(message: String) -> Bool {
        state.withLock { $0.take(message: message) }
    }
}
