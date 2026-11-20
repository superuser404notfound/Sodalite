import Testing
import Foundation
import AetherEngine
@testable import Sodalite

@MainActor
struct PlayerViewModelEngineInjectionTests {
    private func makeVM(engine: AetherEngine? = nil, role: SharedOutputRole = .primary) -> PlayerViewModel {
        let channel = JellyfinChannel(id: "c1", name: "c1", channelNumber: nil, imageTags: nil, currentProgram: nil, userData: nil)
        return PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: RecordingPlaybackService(),
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.engineinjection.\(UUID())")!),
            isLiveSession: true, liveChannel: channel,
            engine: engine, sharedOutputRole: role)
    }

    @Test("without an engine the view model plays on the app's engine, as before")
    func defaultsToAppEngine() {
        #expect(makeVM().player === DependencyContainer.playerEngine)
    }

    @Test("a tile view model plays on the engine it was given")
    func usesInjectedEngine() throws {
        let engine = try AetherEngine()
        #expect(makeVM(engine: engine).player === engine)
    }

    @Test("the role is kept and can be promoted")
    func roleIsStoredAndMutable() throws {
        let vm = makeVM(engine: try AetherEngine(), role: .secondary)
        #expect(vm.sharedOutputRole == .secondary)
        vm.sharedOutputRole = .primary
        #expect(vm.sharedOutputRole == .primary)
    }

    @Test("a multiview tile never wipes the shared ASS font cache on stop")
    func tileStopKeepsFontCache() {
        #expect(PlayerViewModel.clearsSharedFontCacheOnStop(isMultiviewTile: true) == false)
        #expect(PlayerViewModel.clearsSharedFontCacheOnStop(isMultiviewTile: false) == true)
    }
}
