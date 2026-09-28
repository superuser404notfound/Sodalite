import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: a rung switch is a new stream. The old server session must close (report + encode
/// kill, or the server keeps an ffmpeg running), and the new one must start where the viewer was.
@MainActor
struct StreamingQualitySwitchTests {
    private func makeViewModel(_ service: RecordingPlaybackService) throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","RunTimeTicks":36000000000}"#.utf8))
        return PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: service, userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.qualitySwitch.\(UUID().uuidString)")!))
    }

    private func settle(_ service: RecordingPlaybackService, kills: Int, infos: Int) async {
        for _ in 0..<300 where service.killedEncodings.count < kills || service.requestedCaps.count < infos {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func aSwitchClosesTheOldSessionAndReopensAtTheNewCap() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .original
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.mediaSourceID = "src-1"
        vm.playbackTime = 1200

        vm.selectStreamingQuality(.mbps4)
        await settle(service, kills: 1, infos: 1)

        #expect(vm.streamingQuality == .mbps4)
        #expect(service.stoppedReports.map(\.playSessionId) == ["ps-1"])
        #expect(service.stoppedReports.first?.positionTicks == 12_000_000_000)
        #expect(service.killedEncodings == ["ps-1"])
        #expect(service.requestedCaps == [4_000_000])
    }

    @Test func pickingTheActiveRungDoesNothing() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .mbps10
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"

        vm.selectStreamingQuality(.mbps10)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(service.stoppedReports.isEmpty)
        #expect(service.killedEncodings.isEmpty)
        #expect(service.requestedCaps.isEmpty)
    }

    @Test func twoSwitchesCloseEachSessionOnce() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .original
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"

        vm.selectStreamingQuality(.mbps10)
        // What the reopened session would have been given by the server.
        vm.hasReportedStart = true
        vm.playSessionID = "ps-2"
        vm.selectStreamingQuality(.mbps2)
        await settle(service, kills: 2, infos: 2)

        #expect(vm.streamingQuality == .mbps2)
        // The two closes run detached, so their order is not the test's to pin.
        #expect(service.killedEncodings.sorted() == ["ps-1", "ps-2"])
        #expect(service.requestedCaps.last == 2_000_000)
    }
}
