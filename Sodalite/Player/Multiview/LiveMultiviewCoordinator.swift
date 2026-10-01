#if os(tvOS)
import AVFoundation
import AetherEngine
import UIKit

/// What the channel picker was opened for.
enum MultiviewPickerRequest: Identifiable, Equatable {
    case add
    case replace(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .replace(let tile): "replace-\(tile)"
        }
    }
}

/// Sodalite#175: moves one live view model from the normal player into the grid, between the grid and a
/// tile's full screen, and back. The only owner of those transitions, and of app lifecycle while the grid is up.
@Observable
@MainActor
final class LiveMultiviewCoordinator {
    enum Exit: Equatable {
        case continuing(PlayerViewModel)
        case close

        static func == (lhs: Exit, rhs: Exit) -> Bool {
            switch (lhs, rhs) {
            case let (.continuing(a), .continuing(b)): a === b
            case (.close, .close): true
            default: false
            }
        }
    }

    struct TileFailure: Equatable {
        let title: String
        let body: String
    }

    typealias TileFactory = (JellyfinChannel, AetherEngine) -> PlayerViewModel

    let session: MultiviewSession
    let theme: ResolvedAppearanceTheme
    var pickerRequest: MultiviewPickerRequest?
    /// Nil until the first tile's zap lineup has loaded.
    private(set) var lineup: [JellyfinChannel]?

    @ObservationIgnored private weak var host: UIViewController?
    /// What presented the player this came from; after a PiP restore that is not the launcher host.
    @ObservationIgnored private weak var presenter: UIViewController?
    @ObservationIgnored private weak var grid: MultiviewHostController?
    @ObservationIgnored private let makeTileVM: TileFactory
    @ObservationIgnored private let onPlayerDismiss: () -> Void
    @ObservationIgnored private var lineupTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var wasBackgrounded = false
    @ObservationIgnored private var suspendTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var suspensionAssertion: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var finished = false
    /// Each tile's frame in window coordinates, as the grid last laid it out.
    @ObservationIgnored var tileFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private let zoom = MultiviewZoomTransition()

    init(
        host: UIViewController,
        presenter: UIViewController? = nil,
        first: PlayerViewModel,
        channel: JellyfinChannel,
        makeTileVM: @escaping TileFactory,
        theme: ResolvedAppearanceTheme,
        onPlayerDismiss: @escaping () -> Void
    ) {
        self.host = host
        self.presenter = presenter ?? host
        self.theme = theme
        self.makeTileVM = makeTileVM
        self.onPlayerDismiss = onPlayerDismiss
        session = MultiviewSession(
            first: first,
            channel: channel,
            pool: DependencyContainer.multiviewEnginePool,
            makeTileVM: { channel, engine in
                let vm = makeTileVM(channel, engine)
                Self.armTileEnd(vm)
                return vm
            }
        )
    }

    // MARK: - Pure policy

    static func pickerChannels(lineup: [JellyfinChannel], onTiles: Set<String>) -> [JellyfinChannel] {
        lineup.filter { !onTiles.contains($0.id) }
    }

    /// `end()` hands back nothing when a racing path emptied the session, and a stopped view model must
    /// never be handed to a `.continuing` player.
    static func exit(after survivor: PlayerViewModel?) -> Exit {
        guard let survivor, !survivor.didStopPlayback else { return .close }
        return .continuing(survivor)
    }

    static func tileFailure(refusal: LiveTuneRefusal?, errorTitle: String?, errorMessage: String?) -> TileFailure? {
        if let refusal { return TileFailure(title: refusal.title, body: refusal.body) }
        guard let errorMessage else { return nil }
        return TileFailure(title: errorTitle ?? "", body: errorMessage)
    }

    /// A tile has no player to close when its stream ends; it shows as failed and the viewer removes or replaces it.
    static func armTileEnd(_ vm: PlayerViewModel) {
        vm.onPlaybackReachedEnd = { [weak vm] in
            guard let vm, vm.errorMessage == nil, vm.tileRefusal == nil else { return }
            vm.setLiveChannelUnavailableError()
        }
    }

    /// Lets a live player hand its view model to a new multiview session from `host`.
    static func wireEntry(
        _ controller: PlayerHostController,
        host: PlayerLauncherHostVC,
        fallbackChannel: JellyfinChannel,
        makeTileVM: @escaping TileFactory,
        theme: ResolvedAppearanceTheme,
        onPlayerDismiss: @escaping () -> Void
    ) {
        controller.onEnterMultiview = { [weak controller] vm in
            let coordinator = LiveMultiviewCoordinator(
                host: host,
                presenter: controller?.presentingViewController ?? host,
                first: vm,
                channel: vm.liveChannel ?? fallbackChannel,
                makeTileVM: makeTileVM,
                theme: theme,
                onPlayerDismiss: onPlayerDismiss
            )
            host.multiview = coordinator
            guard coordinator.start() else {
                if host.multiview === coordinator { host.multiview = nil }
                vm.isMultiviewTile = false
                return false
            }
            return true
        }
    }

    // MARK: - Transitions

    /// Decides synchronously: true means the session owns the view model from here.
    @discardableResult
    func start() -> Bool {
        guard let presenter = presenter ?? host, grid == nil, !finished else { return false }
        // The player it came from wrote its own end handler; that controller is gone.
        if let first = session.tiles.first?.viewModel { Self.armTileEnd(first) }
        LogTap.shared.note("[Multiview] enter channel=\(session.tiles.first?.currentChannel.id ?? "?")")
        // A session whose view model is tile 1 is the one being restored; ending it would stop tile 1.
        if let first = session.tiles.first?.viewModel, PiPSessionCoordinator.shared.activeViewModel !== first {
            PiPSessionCoordinator.shared.endActiveSession()
        }
        let grid = MultiviewHostController(coordinator: self)
        self.grid = grid
        UIApplication.shared.isIdleTimerDisabled = true
        observeAppLifecycle()
        loadLineupIfNeeded()
        presenter.dismiss(animated: false) { [weak self] in
            presenter.present(grid, animated: false) {
                self?.pickerRequest = .add
            }
        }
        return true
    }

    func showFullScreen(_ id: UUID) {
        guard !finished, let grid, grid.presentedViewController == nil,
              let tile = session.tiles.first(where: { $0.id == id }) else { return }
        session.setAudible(id)
        let vm = tile.viewModel
        // Zapping stays, but never onto a channel another tile shows: Jellyfin keys open streams by channel.
        vm.zapSkipsChannelIDs = { [weak self] in
            guard let self else { return [] }
            return Set(self.session.tiles.filter { $0.id != id }.map(\.currentChannel.id))
        }
        weak var fullScreen: PlayerHostController?
        let controller = PlayerHostController(
            viewModel: vm,
            theme: theme,
            mode: .multiviewTile,
            onDismiss: { [weak self, weak grid] in
                // Called by Back and possibly again by the dismiss that follows it.
                guard let grid, let shown = fullScreen, grid.presentedViewController === shown,
                      !shown.isBeingDismissed else { return }
                let dismiss = { [weak self, weak grid] in
                    guard let grid, grid.presentedViewController === shown, !shown.isBeingDismissed else { return }
                    let animated = self?.armZoom(on: shown, tile: id) ?? false
                    grid.dismiss(animated: animated)
                    self?.gridDidAppear()
                }
                // Back during the zoom in: UIKit drops a dismiss that overlaps a presentation, so it waits for
                // the presentation to land, one turn later, and gets one more try if it still did not take.
                if let transition = shown.transitionCoordinator, shown.isBeingPresented {
                    transition.animate(alongsideTransition: nil) { _ in
                        DispatchQueue.main.async { [weak grid] in
                            dismiss()
                            guard let grid, grid.presentedViewController === shown, !shown.isBeingDismissed else { return }
                            LogTap.shared.note("[Multiview] full screen dismiss after zoom-in did not take, retrying")
                            DispatchQueue.main.async { dismiss() }
                        }
                    }
                } else {
                    dismiss()
                }
            }
        )
        fullScreen = controller
        controller.modalPresentationStyle = .fullScreen
        grid.present(controller, animated: armZoom(on: controller, tile: id))
    }

    /// Zooms between the tile and full screen when the tile's frame is known and Reduce Motion is off,
    /// else the plain cut it always was.
    private func armZoom(on controller: UIViewController, tile id: UUID) -> Bool {
        guard let frame = MultiviewZoomTransition.zoomFrame(
            tileFrame: tileFrames[id], reduceMotion: UIAccessibility.isReduceMotionEnabled) else {
            controller.transitioningDelegate = nil
            return false
        }
        zoom.tileFrame = frame
        controller.transitioningDelegate = zoom
        return true
    }

    /// The grid is on screen again: every tile's end handler is ours, whatever a full screen wrote meanwhile.
    func gridDidAppear() {
        for tile in session.tiles {
            tile.viewModel.zapSkipsChannelIDs = nil
            Self.armTileEnd(tile.viewModel)
            // Ended while its full screen was up: that player closed itself, the tile is still dead.
            if tile.viewModel.player.state == .ended { tile.viewModel.onPlaybackReachedEnd?() }
        }
    }

    func remove(_ id: UUID) {
        guard !finished else { return }
        session.remove(id)
        // A replaced tile keeps its id and its place, so only a removed one loses its frame.
        tileFrames[id] = nil
        if session.shouldEnd || session.tiles.isEmpty { end() }
    }

    func choose(_ channel: JellyfinChannel, for request: MultiviewPickerRequest) {
        pickerRequest = nil
        guard !finished else { return }
        do {
            switch request {
            case .add: try session.add(channel)
            case .replace(let id): try session.replace(id, with: channel)
            }
        } catch {
            LogTap.shared.note("[Multiview] \(request.id) channel=\(channel.id) failed: \(error)")
        }
    }

    func channelsOnTiles() -> Set<String> {
        session.channelsOnTiles()
    }

    func pickerChannels() -> [JellyfinChannel]? {
        lineup.map { Self.pickerChannels(lineup: $0, onTiles: channelsOnTiles()) }
    }

    /// Back in the grid, or one tile left: the audible tile carries on in the normal player.
    func end() {
        guard !finished else { return }
        finished = true
        let survivorChannel = session.tiles.first(where: { $0.id == session.audibleTileID })?.currentChannel
            ?? session.tiles.first?.currentChannel
        let survivor = session.end()
        survivor?.zapSkipsChannelIDs = nil
        tearDownLifecycle()
        let presenter = grid?.presentingViewController ?? self.presenter ?? host
        switch Self.exit(after: survivor) {
        case .continuing(let vm):
            LogTap.shared.note("[Multiview] end, continuing channel=\(vm.liveChannel?.id ?? "?")")
            guard let presenter, let launcherHost = host as? PlayerLauncherHostVC,
                  let channel = vm.liveChannel ?? survivorChannel else {
                vm.stopPlayback()
                close()
                return
            }
            let controller = PlayerHostController(
                viewModel: vm, theme: theme, mode: .continuing, onDismiss: onPlayerDismiss)
            controller.modalPresentationStyle = .fullScreen
            Self.wireEntry(
                controller,
                host: launcherHost,
                fallbackChannel: channel,
                makeTileVM: makeTileVM,
                theme: theme,
                onPlayerDismiss: onPlayerDismiss
            )
            presenter.dismiss(animated: false) { [weak self] in
                presenter.present(controller, animated: false) {
                    if launcherHost.multiview === self { launcherHost.multiview = nil }
                }
            }
        case .close:
            LogTap.shared.note("[Multiview] end, nothing left to continue")
            close()
        }
    }

    /// Deep link, sign-out, programmatic dismissal: every tile stops and the grid closes.
    func stopAll() {
        guard !finished else { return }
        finished = true
        LogTap.shared.note("[Multiview] stop all tiles=\(session.tiles.count)")
        session.stopAll()
        tearDownLifecycle()
        close()
    }

    private func close() {
        let presenter = grid?.presentingViewController
        onPlayerDismiss()
        if let launcherHost = host as? PlayerLauncherHostVC, launcherHost.multiview === self {
            launcherHost.multiview = nil
        }
        // The launcher's dismiss runs from its host; a grid presented from elsewhere still has to go.
        if let presenter, let grid, presenter.presentedViewController === grid {
            presenter.dismiss(animated: false)
        }
    }

    // MARK: - Lineup

    func loadLineupIfNeeded() {
        guard lineup == nil, lineupTask == nil,
              let source = session.tiles.first(where: { !$0.viewModel.isTearingDown })?.viewModel else { return }
        lineupTask = Task { [weak self] in
            source.loadZapLineupIfNeeded()
            let loaded = await source.zapLineupTask?.value ?? source.zapLineup
            guard let self else { return }
            self.lineupTask = nil
            // A failed fetch stays nil, so the picker's next appearance asks again.
            if let loaded { self.lineup = loaded.channels }
        }
    }

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidEnterBackground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            },
        ]
    }

    private func appDidEnterBackground() {
        guard !finished else { return }
        LogTap.shared.note("[Multiview] background, suspending tiles=\(session.tiles.count)")
        wasBackgrounded = true
        resumeTask?.cancel()
        for tile in session.tiles { tile.viewModel.setAppActive(false) }
        suspendTask?.cancel()
        endSuspensionAssertion()
        // Held strongly on purpose, like the player's own release: an assertion nobody ends is a termination.
        suspensionAssertion = UIApplication.shared.beginBackgroundTask(withName: "multiview-tuner-release") {
            self.suspendTask?.cancel()
            self.endSuspensionAssertion()
        }
        let session = session
        suspendTask = Task { @MainActor in
            await session.suspendAll()
            self.suspendTask = nil
            self.endSuspensionAssertion()
        }
    }

    private func appDidBecomeActive() {
        guard !finished, wasBackgrounded else { return }
        wasBackgrounded = false
        LogTap.shared.note("[Multiview] foreground, retuning tiles=\(session.tiles.count)")
        suspendTask?.cancel()
        suspendTask = nil
        endSuspensionAssertion()
        for tile in session.tiles { tile.viewModel.setAppActive(true) }
        // tvOS deactivates the audio session on background; the retunes need it back.
        try? AVAudioSession.sharedInstance().setActive(true)
        let session = session
        resumeTask = Task { @MainActor in
            await session.resumeAll()
        }
    }

    private func endSuspensionAssertion() {
        guard suspensionAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(suspensionAssertion)
        suspensionAssertion = .invalid
    }

    /// From here the continuing player, if any, owns lifecycle.
    private func tearDownLifecycle() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        suspendTask?.cancel()
        suspendTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        endSuspensionAssertion()
        lineupTask?.cancel()
        lineupTask = nil
        pickerRequest = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
#endif
