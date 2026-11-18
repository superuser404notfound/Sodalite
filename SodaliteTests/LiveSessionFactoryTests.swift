import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// The live launcher, the tile factory and the Mac launcher build their view model from one place.
/// Audit 2026-11-17 PHOST-R204.
@MainActor
struct LiveSessionFactoryTests {

    private func factory() -> LiveSessionFactory {
        LiveSessionFactory(
            playbackService: RecordingPlaybackService(),
            liveTvService: StubGuideService(),
            userID: "user-2",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.livefactory.\(UUID())")!),
            directStreamMemory: LiveDirectStreamMemory(keychain: InMemoryKeychain()),
            canTranscodeAudio: false, serverName: "Second", serverReachability: { .reachable })
    }

    private func channel(_ id: String) -> JellyfinChannel {
        JellyfinChannel(id: id, name: id, channelNumber: nil, imageTags: nil, currentProgram: nil, userData: nil)
    }

    @Test func theViewModelCarriesEveryDependencyOfTheFactory() {
        let vm = factory().makeViewModel(channel: channel("c1"), program: nil, zapFilter: .default)
        #expect(vm.isLiveSession)
        #expect(vm.userID == "user-2")
        #expect(vm.canTranscodeAudio == false)
        #expect(vm.serverName == "Second")
        #expect(vm.serverReachability() == .reachable)
        #expect(vm.liveChannel?.id == "c1")
        #expect(vm.sharedOutputRole == .primary)
    }

    @Test func aTileRoleAndEngineAreHandedThrough() throws {
        let engine = try AetherEngine()
        let vm = factory().makeViewModel(
            channel: channel("c2"), program: nil, zapFilter: .default, engine: engine, role: .secondary)
        #expect(vm.player === engine)
        #expect(vm.sharedOutputRole == .secondary)
    }
}
