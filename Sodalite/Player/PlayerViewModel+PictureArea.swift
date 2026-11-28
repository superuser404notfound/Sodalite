import Foundation
import AetherEngine

/// Sodalite#118: Fill (Auto) learns where the picture sits inside the frame. A scan starts once a
/// VOD title shows its first frame, runs a first pass over twelve keyframes and then keeps reading
/// ahead of the playhead, so a wider passage widens the area before it is on screen.
extension PlayerViewModel {
    /// How often the look-ahead takes its next sample while playing.
    static let pictureAreaLookAheadInterval: Duration = .seconds(10)

    /// A handle on a running scan, so tests can wait for its first pass.
    struct PictureAreaRun {
        let firstPass: Task<Void, Never>
        func firstPassDone() async { await firstPass.value }
    }

    static func shouldScanPictureArea(choice: PictureChoice, hasStartedPlaying: Bool,
                                      isLive: Bool, isPreroll: Bool) -> Bool {
        choice == .fill(.auto) && hasStartedPlaying && !isLive && !isPreroll
    }

    var pictureAreaCacheKey: String {
        PictureAreaCache.key(serverID: item.serverID, itemID: item.id, mediaSourceID: mediaSourceID)
    }

    /// Called once the stills URL of a session is known (nil: this source has none). A cached area
    /// applies right away, before the first frame.
    func preparePictureArea(scanURL: URL?) {
        pictureAreaScanURL = scanURL
        if let cached = pictureAreaCache.area(for: pictureAreaCacheKey) {
            detectedPictureArea = cached
            provisionalPictureArea = nil
            if cached.isFullFrame { pictureAreaScanState = .finished }
            applyPictureMode()
        }
    }

    func startPictureAreaScanIfNeeded() {
        guard pictureAreaTask == nil,
              Self.shouldScanPictureArea(choice: activePictureChoice, hasStartedPlaying: hasStartedPlaying,
                                         isLive: isLiveSession, isPreroll: isPlayingPreroll) else { return }
        guard detectedPictureArea?.isFullFrame != true else {
            pictureAreaScanState = .finished
            return
        }
        guard let url = pictureAreaScanURL else {
            if pictureAreaScanState != .unavailable {
                LogTap.shared.note("[PictureArea] no scan: this source has no stills URL")
            }
            pictureAreaScanState = .unavailable
            dropProvisionalPictureArea()
            return
        }
        // The engine can publish its duration after the first `.playing`; the item's runtime covers
        // that gap, and the next call retries anything else that is not known yet.
        let runtime = item.runTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        let duration = player.duration > 0 ? player.duration : runtime
        let size = videoSize
        guard duration > 0, size.width > 0, size.height > 0 else {
            LogTap.shared.note("[PictureArea] scan deferred: duration=\(Int(duration)) size=\(Int(size.width))x\(Int(size.height))")
            schedulePictureAreaRetry()
            return
        }
        // Its own extractor: one in-flight decode per extractor, and a scan sample must never cancel
        // the scrub preview the viewer is looking at.
        let extractor = player.makeFrameExtractor(url: url)
        pictureAreaExtractor = extractor
        LogTap.shared.note("[PictureArea] scan started: duration=\(Int(duration))s seeded=\(detectedPictureArea != nil)")
        _ = runPictureAreaScan(source: extractor, duration: duration,
                               displayAspect: Double(size.width / size.height))
    }

    @discardableResult
    func runPictureAreaScan(source: any StillSource, duration: Double, displayAspect: Double) -> PictureAreaRun {
        let scanner = PictureAreaScanner(source: source, duration: duration, displayAspect: displayAspect,
                                         seed: detectedPictureArea)
        let generation = sessionGeneration
        pictureAreaScanID &+= 1
        let scanID = pictureAreaScanID
        pictureAreaScanState = .scanning
        let first = Task { [weak self] in
            let area = await scanner.firstPass()
            guard !Task.isCancelled, let self, self.isCurrentPictureAreaScan(scanID, generation) else { return }
            if let area {
                self.acceptPictureArea(area)
            } else {
                // Too few usable frames. The look-ahead keeps trying, but the previous episode's zoom
                // has no business on this one meanwhile.
                self.dropProvisionalPictureArea()
            }
        }
        pictureAreaTask = Task { [weak self] in
            // The first pass is its own task; a stop cancels this one, and the cancel has to reach it.
            await withTaskCancellationHandler { await first.value } onCancel: { first.cancel() }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pictureAreaLookAheadInterval)
                guard !Task.isCancelled, let self, self.isCurrentPictureAreaScan(scanID, generation) else { return }
                if await scanner.current?.isFullFrame == true { return }
                guard self.activePictureChoice == .fill(.auto), self.isPlaying else { continue }
                let playhead = self.player.currentTime
                if let wider = await scanner.advance(playhead: playhead),
                   self.isCurrentPictureAreaScan(scanID, generation) {
                    self.acceptPictureArea(wider)
                }
            }
        }
        return PictureAreaRun(firstPass: first)
    }

    private func isCurrentPictureAreaScan(_ scanID: Int, _ generation: Int) -> Bool {
        pictureAreaScanID == scanID && sessionGeneration == generation
    }

    private func dropProvisionalPictureArea() {
        guard provisionalPictureArea != nil else { return }
        provisionalPictureArea = nil
        applyPictureMode(animated: true)
    }

    private func acceptPictureArea(_ area: PictureArea) {
        pictureAreaScanState = .finished
        let hadProvisional = provisionalPictureArea != nil
        provisionalPictureArea = nil
        guard area != detectedPictureArea || hadProvisional else { return }
        detectedPictureArea = area
        applyPictureMode(animated: true)
        pictureAreaCache.store(area, for: pictureAreaCacheKey)
    }

    /// The presented size can arrive after the first `.playing`; ask again shortly instead of waiting
    /// for a pause and resume. A few tries, then the next `.playing` or choice change takes over.
    private func schedulePictureAreaRetry() {
        guard pictureAreaRetries < 5 else { return }
        pictureAreaRetries += 1
        let generation = sessionGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sessionGeneration == generation else { return }
            self.startPictureAreaScanIfNeeded()
        }
    }

    /// Each new item starts from the Picture Size preference, so a pick does not bleed into the next
    /// episode or film. A same-item reload (quality change, outage retry, audio reopen) keeps the pick:
    /// a hand-picked ratio is how the viewer overrides a wrong detection.
    func applySessionPictureChoice() {
        if pictureChoiceCarries {
            pictureChoiceCarries = false
            return
        }
        pictureMode = preferences.pictureMode
        fillRatio = .auto
    }

    /// For a reload that plays another file under the same session (item recovery): the old file's
    /// area says nothing about the new one.
    func forgetPictureArea() {
        stopPictureAreaScan()
        detectedPictureArea = nil
        provisionalPictureArea = nil
        pictureAreaScanState = .idle
        pictureAreaScanURL = nil
    }

    func stopPictureAreaScan() {
        pictureAreaScanID &+= 1
        pictureAreaTask?.cancel()
        pictureAreaTask = nil
        pictureAreaRetries = 0
        let extractor = pictureAreaExtractor
        pictureAreaExtractor = nil
        Task { await extractor?.shutdown() }
    }
}
