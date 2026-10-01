import Foundation
import AetherEngine

struct MultiviewTile: Identifiable {
    let id: UUID
    var channel: JellyfinChannel
    var viewModel: PlayerViewModel
    let slot: Int
}

enum MultiviewError: Error, Equatable {
    case full
}

@Observable
@MainActor
final class MultiviewSession {
    static let maxTiles = 4

    private(set) var tiles: [MultiviewTile]
    private(set) var audibleTileID: UUID

    @ObservationIgnored private let pool: MultiviewEnginePool
    @ObservationIgnored private let makeTileVM: (JellyfinChannel, AetherEngine) -> PlayerViewModel
    @ObservationIgnored private let audioFollowDelay: Duration
    @ObservationIgnored private let retune: (PlayerViewModel) async -> Void
    @ObservationIgnored private let suspend: (PlayerViewModel) async -> Void
    @ObservationIgnored private var pendingAudio: Task<Void, Never>?

    init(
        first: PlayerViewModel,
        channel: JellyfinChannel,
        pool: MultiviewEnginePool,
        makeTileVM: @escaping (JellyfinChannel, AetherEngine) -> PlayerViewModel,
        audioFollowDelay: Duration = .milliseconds(300),
        retune: @escaping (PlayerViewModel) async -> Void = { await $0.retuneLiveStream() },
        suspend: @escaping (PlayerViewModel) async -> Void = {
            await $0.releaseLiveSessionForSuspension(waitingForTeardownUpTo: 18)
        }
    ) {
        // The first tile is the channel already on screen: it keeps playing on whatever engine it has.
        first.isMultiviewTile = true
        let tile = MultiviewTile(id: UUID(), channel: channel, viewModel: first, slot: 0)
        tiles = [tile]
        audibleTileID = tile.id
        self.pool = pool
        self.makeTileVM = makeTileVM
        self.audioFollowDelay = audioFollowDelay
        self.retune = retune
        self.suspend = suspend
        applyVolumes()
    }

    var canAddTile: Bool { tiles.count < Self.maxTiles }

    var shouldEnd: Bool { tiles.count == 1 }

    func channelsOnTiles() -> Set<String> {
        Set(tiles.map(\.channel.id))
    }

    func add(_ channel: JellyfinChannel) throws {
        guard canAddTile else { throw MultiviewError.full }
        let used = Set(tiles.map(\.slot))
        guard let slot = (0..<Self.maxTiles).first(where: { !used.contains($0) }) else { throw MultiviewError.full }
        let engine = try pool.engine(forSlot: slot)
        let vm = makeTileVM(channel, engine)
        vm.isMultiviewTile = true
        vm.sharedOutputRole = .secondary
        tiles.append(MultiviewTile(id: UUID(), channel: channel, viewModel: vm, slot: slot))
        applyVolumes()
        vm.beginPlayback()
    }

    func replace(_ id: UUID, with channel: JellyfinChannel) throws {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let old = tiles[index].viewModel
        old.stopPlayback()
        let vm = makeTileVM(channel, old.player)
        vm.isMultiviewTile = true
        vm.sharedOutputRole = old.sharedOutputRole
        tiles[index].channel = channel
        tiles[index].viewModel = vm
        applyVolumes()
        vm.beginPlayback()
    }

    func remove(_ id: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].viewModel.stopPlayback()
        tiles.remove(at: index)
        if id == audibleTileID, let first = tiles.first {
            audibleTileID = first.id
        }
        applyVolumes()
    }

    func focusDidMove(to id: UUID) {
        pendingAudio?.cancel()
        let delay = audioFollowDelay
        pendingAudio = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.setAudible(id)
        }
    }

    func setAudible(_ id: UUID) {
        guard tiles.contains(where: { $0.id == id }) else { return }
        audibleTileID = id
        applyVolumes()
    }

    /// Back to a single player: the audible tile survives as the primary, everything else stops.
    func end() -> PlayerViewModel? {
        pendingAudio?.cancel()
        pendingAudio = nil
        guard !tiles.isEmpty else { return nil }
        let survivorIndex = tiles.firstIndex(where: { $0.id == audibleTileID }) ?? 0
        let survivor = tiles[survivorIndex].viewModel
        for (index, tile) in tiles.enumerated() where index != survivorIndex {
            tile.viewModel.stopPlayback()
        }
        survivor.sharedOutputRole = .primary
        survivor.isMultiviewTile = false
        tiles = []
        return survivor
    }

    func stopAll() {
        pendingAudio?.cancel()
        pendingAudio = nil
        for tile in tiles {
            tile.viewModel.stopPlayback()
        }
        tiles = []
    }

    func suspendAll() async {
        for tile in tiles {
            await suspend(tile.viewModel)
        }
    }

    /// One tune at a time, the audible one first, so the tile with sound is the one that comes back first.
    func resumeAll() async {
        let ordered = tiles.filter { $0.id == audibleTileID } + tiles.filter { $0.id != audibleTileID }
        for tile in ordered {
            await retune(tile.viewModel)
        }
    }

    private func applyVolumes() {
        for tile in tiles {
            tile.viewModel.player.volume = tile.id == audibleTileID ? 1 : 0
        }
    }
}
