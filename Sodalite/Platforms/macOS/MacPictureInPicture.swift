#if os(macOS)
import AppKit
import AVKit
import Combine
import CoreMedia
import AetherEngine

/// Picture in Picture for the Mac player. Unlike tvOS, which covers AVKit's layer with a second one
/// of its own, the Mac builds the controller straight on the layer the engine draws into: the
/// native path's `nativePlayerLayer`, or the software path's sample-buffer layer. While the
/// window floats, the player window steps aside; it comes back when the floating one closes.
@MainActor
final class MacPictureInPicture: NSObject {
    private var controller: AVPictureInPictureController?
    private var boundLayer: CALayer?
    private var boundSoftwareSource: SoftwarePiPSource?
    private var possibleObservation: NSKeyValueObservation?
    private var subscriptions = Set<AnyCancellable>()
    private weak var viewModel: PlayerViewModel?
    private var window: () -> NSWindow? = { nil }

    func attach(to viewModel: PlayerViewModel, window: @escaping () -> NSWindow?) {
        guard self.viewModel == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.viewModel = viewModel
        self.window = window
        viewModel.onPiPStartRequested = { [weak self] in self?.controller?.startPictureInPicture() }
        let engine = viewModel.player
        // Both sources settle on the main queue after a load; either one changing re-reads both, so
        // a native-to-software switch (or the reverse) rebuilds on whichever layer is there now.
        engine.$currentAVPlayer
            .map { _ in () }
            .merge(with: engine.$softwarePiPSource.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebind() }
            .store(in: &subscriptions)
    }

    func detach() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        subscriptions.removeAll()
        tearDownController()
        viewModel?.onPiPStartRequested = nil
        viewModel = nil
    }

    private func rebind() {
        guard let viewModel else { return }
        let engine = viewModel.player
        // An open window keeps its controller across a reload (next episode, audio switch): the
        // engine hands the session over in place while `pictureInPictureActive` is set.
        // A reload that changes the route (software to native or back) swaps the source under the
        // open window rather than leaving it on a layer nothing draws into any more.
        if controller?.isPictureInPictureActive == true {
            if let layer = engine.nativePlayerLayer, layer !== boundLayer {
                boundSoftwareSource = nil
                boundLayer = layer
                controller?.contentSource = .init(playerLayer: layer)
            } else if let source = engine.softwarePiPSource, source.layer !== boundLayer {
                boundSoftwareSource = source
                boundLayer = source.layer
                controller?.contentSource = .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self)
            }
            return
        }
        if let layer = engine.nativePlayerLayer {
            guard layer !== boundLayer else { return }
            tearDownController()
            boundLayer = layer
            install(AVPictureInPictureController(playerLayer: layer))
        } else if let source = engine.softwarePiPSource {
            guard source.layer !== boundLayer else { return }
            tearDownController()
            boundSoftwareSource = source
            boundLayer = source.layer
            install(AVPictureInPictureController(
                contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self)))
        } else {
            tearDownController()
        }
    }

    private func install(_ pip: AVPictureInPictureController?) {
        guard let pip else {
            LogTap.shared.note("[PiP] mac controller init failed")
            return
        }
        pip.delegate = self
        controller = pip
        viewModel?.isPiPAvailable = true
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new, .initial]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.viewModel?.isPiPPossible = possible }
        }
    }

    private func tearDownController() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller = nil
        boundLayer = nil
        boundSoftwareSource = nil
        viewModel?.isPiPAvailable = false
        viewModel?.isPiPPossible = false
    }

    private func setActive(_ active: Bool) {
        viewModel?.player.pictureInPictureActive = active
        if active {
            window()?.orderOut(nil)
        } else {
            window()?.makeKeyAndOrderFront(nil)
        }
    }
}

extension MacPictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] mac willStart")
        setActive(true)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        LogTap.shared.note("[PiP] mac failedToStart: \(error.localizedDescription)")
        setActive(false)
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        window()?.makeKeyAndOrderFront(nil)
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] mac didStop")
        setActive(false)
        // A reload that landed while the window floated was held off; bind what is there now.
        rebind()
    }
}

extension MacPictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        boundSoftwareSource?.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        boundSoftwareSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        boundSoftwareSource?.isPaused ?? true
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        boundSoftwareSource?.skip(by: skipInterval.seconds)
        completionHandler()
    }
}
#endif
