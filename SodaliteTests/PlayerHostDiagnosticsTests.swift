import Testing
import Foundation
import AetherEngine
@testable import Sodalite

@MainActor
struct PlayerHostDiagnosticsTests {
    private func makeHost(_ mode: PlayerPresentationMode) throws -> PlayerHostController {
        let channel = JellyfinChannel(id: "c", name: "c", channelNumber: nil, imageTags: nil, currentProgram: nil, userData: nil)
        let vm = PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: RecordingPlaybackService(),
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.hostdiag.\(UUID())")!),
            isLiveSession: true, liveChannel: channel,
            engine: try AetherEngine(), sharedOutputRole: .primary)
        return PlayerHostController(viewModel: vm, theme: .default, mode: mode, onDismiss: {})
    }

    @Test("the listing names a live controller with its mode and never keeps it alive")
    func registryIsWeak() throws {
        weak var gone: PlayerHostController?
        var id = ""
        // The listing hands out autoreleased arrays; the pool is what a run loop turn does in the app.
        try autoreleasepool {
            let host = try makeHost(.multiviewTile)
            gone = host
            id = host.diagnosticID
            #expect(PlayerHostDiagnostics.liveSummary().contains("\(id) multiviewTile"))
        }
        #expect(gone == nil)
        #expect(!PlayerHostDiagnostics.liveHosts.contains { $0.diagnosticID == id })
    }

    @Test("every controller gets its own id")
    func idsAreUnique() throws {
        let a = try makeHost(.standalone)
        let b = try makeHost(.continuing)
        #expect(a.diagnosticID != b.diagnosticID)
    }
}
