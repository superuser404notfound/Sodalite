#if os(tvOS) || os(iOS)
import AVKit
import UIKit
import CoreMedia
import AetherEngine

/// View whose backing layer IS an AVPlayerLayer, so bounds changes track autoresizing without manual layout.
final class PiPSourceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Host-built PiP for the tvOS player: AVKit exposes no API to trigger its own PiP from custom chrome,
/// so this owns an AVPictureInPictureController around a second full-size AVPlayerLayer that covers
/// AVKit's render layer with identical content (same AVPlayer, decode happens once).
@MainActor
final class PlayerPiPController: NSObject {
    let sourceView = PiPSourceView()

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    /// Bound SW-path bridge (sample-buffer mode); nil while in playerLayer mode.
    private var boundSoftwareSource: SoftwarePiPSource?

    var onPossibleChanged: ((Bool) -> Void)?
    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onFailedToStart: ((Error) -> Void)?
    /// AVKit's restore completion MUST be answered exactly once; forwarded to the session coordinator.
    var onRestoreRequested: ((@escaping (Bool) -> Void) -> Void)?
    var onDidStop: (() -> Void)?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    /// Sodalite#175 diagnostics: whether a PiP controller and its source layer still hold a player.
    var diagnosticFacts: String {
        "\(controller == nil ? "none" : (isActive ? "active" : "armed"))/layer=\(sourceView.playerLayer.player == nil ? "nil" : "set")"
    }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    /// (Re)binds the source layer to the engine's current AVPlayer; nil unbinds (SW path / teardown).
    /// Rebinding on the SAME controller keeps an active PiP window across engine reloads (audio switch,
    /// next episode); whether the window survives the player swap is a device-verify item.
    func bind(player: AVPlayer?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // A bound SW source owns the controller; the native sink's nil events must not clobber it.
        if boundSoftwareSource != nil, player == nil { return }
        guard let player else {
            // An engine reload publishes a nil gap (stopInternal) before the fresh player arrives; tearing
            // anything down here would close an open PiP window mid next-episode/audio-switch. While the
            // window is up, keep the controller AND the layer's old (stopped) player until the fresh bind
            // swaps it; a source layer without a player is a system reason to close the window.
            if !isActive {
                sourceView.playerLayer.player = nil
                possibleObservation?.invalidate()
                possibleObservation = nil
                controller = nil
                onPossibleChanged?(false)
            }
            return
        }
        sourceView.playerLayer.player = player
        guard controller == nil else { return }
        guard let pip = AVPictureInPictureController(playerLayer: sourceView.playerLayer) else {
            LogTap.shared.note("[PiP] controller init failed (layer rejected)")
            return
        }
        pip.delegate = self
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new, .initial]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            LogTap.shared.note("[PiP] possible=\(possible)")
            Task { @MainActor [weak self] in self?.onPossibleChanged?(possible) }
        }
    }

    /// (Re)binds the sample-buffer ContentSource for the software path; nil unbinds. Mirrors
    /// bind(player:): the controller survives only while its window is open, and a fresh source
    /// rebuilds it. On iOS the controller also arms auto-PiP on swipe-home (AVKit parity).
    func bind(softwareSource: SoftwarePiPSource?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let source = softwareSource else {
            // Only tear down a SOFTWARE binding: every stopInternal publishes softwarePiPSource = nil
            // (native sessions included), and that event must not clobber a fresh playerLayer controller.
            guard boundSoftwareSource != nil else { return }
            boundSoftwareSource = nil
            if !isActive {
                possibleObservation?.invalidate()
                possibleObservation = nil
                controller = nil
                onPossibleChanged?(false)
            }
            return
        }
        boundSoftwareSource = source
        // Phase B: an active window survives a next-episode reload by swapping the ContentSource to
        // the fresh layer on the SAME controller (the SW reload rebuilds renderer+layer, so the bound
        // layer identity changes mid-window). Inactive controllers keep today's rebuild-on-nil flow.
        if let existing = controller {
            if existing.isPictureInPictureActive,
               existing.contentSource?.sampleBufferDisplayLayer !== source.layer {
                LogTap.shared.note("[PiP] sw contentSource swap (advance)")
                existing.contentSource = AVPictureInPictureController.ContentSource(
                    sampleBufferDisplayLayer: source.layer,
                    playbackDelegate: self
                )
            }
            return
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: source.layer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = self
        #if os(iOS)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new, .initial]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            LogTap.shared.note("[PiP] sw possible=\(possible)")
            Task { @MainActor [weak self] in self?.onPossibleChanged?(possible) }
        }
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        sourceView.playerLayer.videoGravity = gravity
    }
}

// @preconcurrency: AVKit delivers these on the main thread; the MainActor-isolated methods keep willStart
// synchronous so pipActive is set BEFORE the handoff dismiss runs (same ordering contract as the iOS
// AVKit delegate), and the restore completion crosses without a Sendable fight.
extension PlayerPiPController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] willStart")
        onWillStart?()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] didStart")
        onDidStart?()
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        LogTap.shared.note("[PiP] failedToStart: \(error.localizedDescription)")
        onFailedToStart?(error)
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        LogTap.shared.note("[PiP] restore requested")
        onRestoreRequested?(completionHandler)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] didStop")
        onDidStop?()
    }
}

// Thin proxy onto the engine's SoftwarePiPSource; @preconcurrency for the same main-thread
// delivery contract as the window delegate above.
extension PlayerPiPController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        boundSoftwareSource?.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        boundSoftwareSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        boundSoftwareSource?.isPaused ?? true
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        boundSoftwareSource?.skip(by: skipInterval.seconds)
        completionHandler()
    }
}
#endif
