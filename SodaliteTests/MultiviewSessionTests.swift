import Testing
import Foundation
import AetherEngine
@testable import Sodalite

@MainActor
struct MultiviewSessionTests {
    @MainActor
    final class Journal {
        var entries: [String] = []
    }

    private func channel(_ id: String) -> JellyfinChannel {
        JellyfinChannel(id: id, name: id, channelNumber: nil, imageTags: nil, currentProgram: nil, userData: nil)
    }

    private func makeVM(_ channel: JellyfinChannel, engine: AetherEngine, role: SharedOutputRole) -> PlayerViewModel {
        PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: RecordingPlaybackService(),
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.multiview.\(UUID())")!),
            isLiveSession: true, liveChannel: channel,
            engine: engine, sharedOutputRole: role)
    }

    private func makeSession(
        audioFollowDelay: Duration = .milliseconds(300),
        retune: @escaping (PlayerViewModel) async -> Void = { await $0.retuneLiveStream() },
        suspend: @escaping (PlayerViewModel) async -> Void = { await $0.releaseLiveSessionForSuspension(waitingForTeardownUpTo: 18) }
    ) throws -> MultiviewSession {
        let pool = MultiviewEnginePool(primary: try AetherEngine(), make: { try AetherEngine() })
        let first = makeVM(channel("c1"), engine: pool.primary, role: .primary)
        return MultiviewSession(
            first: first, channel: channel("c1"), pool: pool,
            makeTileVM: { [self] channel, engine in makeVM(channel, engine: engine, role: .secondary) },
            audioFollowDelay: audioFollowDelay, retune: retune, suspend: suspend)
    }

    @Test("the first tile keeps playing and is audible")
    func firstTileAudible() throws {
        let session = try makeSession()
        #expect(session.tiles.count == 1)
        let first = try #require(session.tiles.first)
        #expect(session.audibleTileID == first.id)
        #expect(first.viewModel.player.volume == 1)
        #expect(first.viewModel.isMultiviewTile)
        #expect(first.viewModel.didStopPlayback == false)
    }

    @Test("an added tile plays muted on its own secondary engine")
    func addedTileMutedSecondary() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        #expect(session.tiles.count == 2)
        let tile = session.tiles[1]
        #expect(tile.viewModel.player !== session.tiles[0].viewModel.player)
        #expect(tile.viewModel.sharedOutputRole == .secondary)
        #expect(tile.viewModel.isMultiviewTile == true)
        #expect(tile.viewModel.player.volume == 0)
        #expect(session.tiles[0].viewModel.player.volume == 1)
    }

    @Test("no more than four tiles")
    func capsAtFour() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        try session.add(channel("c3"))
        try session.add(channel("c4"))
        #expect(session.tiles.count == 4)
        #expect(session.canAddTile == false)
        #expect(throws: MultiviewError.self) { try session.add(channel("c5")) }
        #expect(session.tiles.count == 4)
    }

    @Test("removing a tile stops it and leaves the others playing")
    func removeStopsTileAndKeepsOthers() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        let t1 = session.tiles[0]
        let t2 = session.tiles[1]
        session.remove(t2.id)
        #expect(t2.viewModel.didStopPlayback == true)
        #expect(t1.viewModel.didStopPlayback == false)
        #expect(session.tiles.count == 1)
        #expect(session.shouldEnd == true)
    }

    @Test("a failed tile is stopped when removed")
    func failedTileIsStoppedOnRemove() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        let t2 = session.tiles[1]
        t2.viewModel.tileRefusal = .tunerUnavailable
        session.remove(t2.id)
        #expect(t2.viewModel.didStopPlayback == true)
        #expect(session.tiles.map(\.id).contains(t2.id) == false)
    }

    @Test("removing the audible tile moves the audio to the first remaining tile")
    func removeAudibleMovesAudio() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        try session.add(channel("c3"))
        let t1 = session.tiles[0]
        let t2 = session.tiles[1]
        let t3 = session.tiles[2]
        session.setAudible(t2.id)
        #expect(t2.viewModel.player.volume == 1)
        session.remove(t2.id)
        #expect(session.audibleTileID == t1.id)
        #expect(t1.viewModel.player.volume == 1)
        #expect(t3.viewModel.player.volume == 0)
    }

    @Test("audio follows focus only after it rests")
    func audioFollowsFocusAfterRest() async throws {
        let session = try makeSession(audioFollowDelay: .milliseconds(50))
        try session.add(channel("c2"))
        try session.add(channel("c3"))
        let t1 = session.tiles[0]
        let t2 = session.tiles[1]
        let t3 = session.tiles[2]
        session.focusDidMove(to: t2.id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.audibleTileID == t1.id)
        session.focusDidMove(to: t3.id)
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.audibleTileID == t3.id)
        #expect(t1.viewModel.player.volume == 0)
        #expect(t2.viewModel.player.volume == 0)
        #expect(t3.viewModel.player.volume == 1)
    }

    @Test("end returns the audible tile, promoted, and stops the rest")
    func endReturnsAudibleSurvivorWithoutStoppingIt() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        try session.add(channel("c3"))
        let t1 = session.tiles[0]
        let t2 = session.tiles[1]
        let t3 = session.tiles[2]
        session.setAudible(t2.id)
        let survivor = session.end()
        #expect(survivor === t2.viewModel)
        #expect(survivor.didStopPlayback == false)
        #expect(survivor.sharedOutputRole == .primary)
        #expect(survivor.isMultiviewTile == false)
        #expect(t1.viewModel.didStopPlayback == true)
        #expect(t3.viewModel.didStopPlayback == true)
        #expect(session.tiles.isEmpty)
    }

    @Test("replacing a channel stops the old tile and starts the new one on the same engine")
    func replaceKeepsSlotEngine() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        let old = session.tiles[1]
        session.setAudible(old.id)
        try session.replace(old.id, with: channel("c9"))
        let new = session.tiles[1]
        #expect(old.viewModel.didStopPlayback == true)
        #expect(new.id == old.id)
        #expect(new.slot == old.slot)
        #expect(new.channel.id == "c9")
        #expect(new.viewModel !== old.viewModel)
        #expect(new.viewModel.player === old.viewModel.player)
        #expect(new.viewModel.liveChannel?.id == "c9")
        #expect(new.viewModel.isMultiviewTile == true)
        #expect(new.viewModel.sharedOutputRole == .secondary)
        #expect(session.audibleTileID == old.id)
        #expect(new.viewModel.player.volume == 1)
        #expect(session.tiles.count == 2)
    }

    @Test("channels already on a tile are reported for the picker to hide")
    func channelsOnTiles() throws {
        let session = try makeSession()
        try session.add(channel("c2"))
        try session.add(channel("c3"))
        #expect(session.channelsOnTiles() == ["c1", "c2", "c3"])
        session.remove(session.tiles[1].id)
        #expect(session.channelsOnTiles() == ["c1", "c3"])
    }

    @Test("on return every tile retunes, audible first, one after another")
    func resumeRetunesAudibleFirstSequentially() async throws {
        let journal = Journal()
        let session = try makeSession(retune: { vm in
            let id = vm.liveChannel?.id ?? "?"
            journal.entries.append("start:\(id)")
            try? await Task.sleep(for: .milliseconds(5))
            journal.entries.append("end:\(id)")
        })
        try session.add(channel("c2"))
        try session.add(channel("c3"))
        session.setAudible(session.tiles[1].id)
        await session.resumeAll()
        #expect(journal.entries == ["start:c2", "end:c2", "start:c1", "end:c1", "start:c3", "end:c3"])
    }

    @Test("on leaving the foreground every tile is suspended, one after another")
    func suspendAllIsSequential() async throws {
        let journal = Journal()
        let session = try makeSession(suspend: { vm in
            let id = vm.liveChannel?.id ?? "?"
            journal.entries.append("start:\(id)")
            try? await Task.sleep(for: .milliseconds(5))
            journal.entries.append("end:\(id)")
        })
        try session.add(channel("c2"))
        await session.suspendAll()
        #expect(journal.entries == ["start:c1", "end:c1", "start:c2", "end:c2"])
    }
}

@MainActor
struct MultiviewEnginePoolTests {
    @Test("slot 0 is the app engine, the others are made once with a tag and kept")
    func slots() throws {
        let primary = try AetherEngine()
        var made = 0
        let pool = MultiviewEnginePool(primary: primary, make: { made += 1; return try AetherEngine() })
        #expect(try pool.engine(forSlot: 0) === primary)
        let second = try pool.engine(forSlot: 1)
        #expect(second !== primary)
        #expect(second.logTag == "tile2")
        #expect(second.deactivatesAudioSessionOnStop == true)
        #expect(try pool.engine(forSlot: 1) === second)
        #expect(made == 1)
    }
}

@MainActor
struct LiveRetuneTileRefusalTests {
    @Test("a retune clears what the previous tune left behind")
    func retuneResetsStaleRefusal() async {
        let channel = JellyfinChannel(id: "c1", name: "c1", channelNumber: nil, imageTags: nil, currentProgram: nil, userData: nil)
        let vm = PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: RecordingPlaybackService(),
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.multiview.retune.\(UUID())")!),
            isLiveSession: true, liveChannel: channel,
            engine: try? AetherEngine(), sharedOutputRole: .secondary)
        vm.isMultiviewTile = true
        vm.lastIngestError = .playlistUnreachable(status: 403)
        vm.tileRefusal = .providerLimit(status: 403)
        await vm.retuneLiveStream()
        #expect(vm.lastIngestError == nil)
        #expect(vm.tileRefusal == nil)
        #expect(vm.lastTunerOpenError != nil)
    }
}
