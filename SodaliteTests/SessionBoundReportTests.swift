import Foundation
import Testing
@testable import Sodalite

/// Audit wave 2, shared root cause 1: every service reads the live client's token and address when a
/// request is sent, so work that finishes after a profile or server switch wrote into the new one.
@Suite("Session-bound reports", .serialized)
@MainActor
struct SessionBoundReportTests {
    private func track(_ id: String, serverID: String? = nil) throws -> JellyfinItem {
        let server = serverID.map { #","ServerId":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Audio"\#(server)}"#.utf8)
        )
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: LTM-201

    @Test func aTracksStopGoesToTheSessionItStartedUnderAfterASwitch() async throws {
        let parent = RecordingPlaybackService()
        let child = RecordingPlaybackService()
        let box = ServiceBox(parent)
        let coordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: parent,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userIDProvider: { "user" },
            bindActiveReporter: { let bound = box.current; return { bound } }
        )
        coordinator.play(queue: [try track("A")], startAt: 0)
        await waitFor { parent.playbackInfoRequests.contains("A") }
        try? await Task.sleep(for: .milliseconds(50))

        // The profile switch: from here the active session answers as the child.
        box.current = child
        coordinator.stop()
        await waitFor { !parent.stoppedReports.isEmpty }

        #expect(parent.stoppedReports.map(\.itemId) == ["A"])
        #expect(child.stoppedReports.isEmpty)
    }

    @Test func aTrackOfAServerThatLeftTheCombinedSetupIsNotPlayedFromTheActiveAccount() async throws {
        let active = RecordingPlaybackService()
        let coordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: active,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userIDProvider: { "user" },
            isRoutable: { $0.serverID != "gone" }
        )
        coordinator.play(queue: [try track("A", serverID: "gone")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(active.playbackInfoRequests.isEmpty)
        coordinator.stop()
        #expect(active.stoppedReports.isEmpty)
    }

    @Test func aServerThatLeftTheRegistryResolvesToNothing() {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        let registry = ServerSessionRegistry(activeClient: live, httpClient: http)
        let server = JellyfinServer(id: "a", name: "a", internalURL: URL(string: "http://a.lan:8096"), externalURL: nil)
        registry.apply(active: (server, "u-a"), secondaries: [], baseURL: { $0.url })
        #expect(registry.resolve(serverID: "a") === registry.active)
        #expect(registry.resolve(serverID: nil) === registry.active)
        #expect(registry.resolve(serverID: "left") == nil)
    }

    @Test func theBoundReporterKeepsTheOldSessionAfterTheTokenChanged() {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        container.verifiesServerIdentity = false
        container.jellyfinClient.baseURL = URL(string: "http://a.lan:8096")
        container.jellyfinClient.accessToken = "tok-parent"
        let reporter = container.boundPlaybackReporter()
        // Built per report from the session as it is then, never the live service (R-W2-1).
        #expect((reporter().map { $0 as AnyObject }) !== (container.jellyfinPlaybackService as AnyObject))
        #expect(reporter()?.baseURL == URL(string: "http://a.lan:8096"))

        container.jellyfinClient.baseURL = URL(string: "http://b.lan:8096")
        container.jellyfinClient.accessToken = "tok-child"

        let service = reporter()
        #expect(service != nil)
        #expect((service.map { $0 as AnyObject }) !== (container.jellyfinPlaybackService as AnyObject))
        #expect(service?.baseURL == URL(string: "http://a.lan:8096"))
    }

    /// The app shape: one live client whose token changes underneath (audit review R-W2-1).
    @Test func aTracksStopReachesTheOldAccountWhenTheSameClientIsSwitchedUnderneath() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Items/A/PlaybackInfo"] = Data(#"{"MediaSources":[{"Id":"src"}],"PlaySessionId":"ps"}"#.utf8)
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(),
            httpClient: http,
            defaults: UserDefaults(suiteName: "r-w2-1-\(UUID().uuidString)")!
        )
        container.verifiesServerIdentity = false
        let serverA = JellyfinServer(id: "srv", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil)
        let parent = try JSONDecoder().decode(JellyfinUser.self, from: Data(#"{"Id":"parent","Name":"P","ServerId":"srv"}"#.utf8))
        try container.saveSession(server: serverA, user: parent, token: "tok-parent")
        container.musicPlaybackCoordinator.play(queue: [try track("A")], startAt: 0)
        await waitFor { http.sent.contains { $0.path == "/Items/A/PlaybackInfo" } }
        try? await Task.sleep(for: .milliseconds(100))

        try container.switchToUser(
            RememberedUser(id: "child", serverID: "srv", name: "C", imageTag: nil, token: "tok-child"), server: serverA)
        await waitFor { http.sent.contains { $0.path == "/Sessions/Playing/Stopped" } }

        let stops = http.sent.filter { $0.path == "/Sessions/Playing/Stopped" }
        #expect(stops.count == 1)
        #expect(stops.first?.headers["Authorization"]?.contains("tok-parent") == true)
        #expect(stops.first?.headers["Authorization"]?.contains("tok-child") == false)
        #expect(stops.first?.baseURL == URL(string: "http://10.0.0.2:8096"))
    }

    @Test func switchingProfilesStopsTheMusicBeforeTheTokenSwaps() throws {
        let keychain = InMemoryKeychain()
        let container = DependencyContainer(keychainService: keychain)
        container.verifiesServerIdentity = false
        let server = JellyfinServer(id: "srv", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil)
        let parent = try JSONDecoder().decode(JellyfinUser.self, from: Data(#"{"Id":"parent","Name":"P","ServerId":"srv"}"#.utf8))
        try container.saveSession(server: server, user: parent, token: "tok-parent")
        container.musicPlaybackCoordinator.play(queue: [try track("A")], startAt: 0)
        #expect(container.musicPlaybackCoordinator.currentItem != nil)

        try container.switchToUser(
            RememberedUser(id: "child", serverID: "srv", name: "C", imageTag: nil, token: "tok-child"), server: server)

        #expect(container.musicPlaybackCoordinator.currentItem == nil)
    }

    // MARK: SHELL-203

    @Test func aDownloadSyncDoesNotWriteIntoTheProfileThatTookOver() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoundSync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(paths: DownloadPaths(root: root))
        let a = ProfileKey(serverID: "s", userID: "a")
        let b = ProfileKey(serverID: "s", userID: "b")
        for profile in [a, b] {
            store.activate(profile)
            var m = DownloadManifest(itemID: "X", seriesID: nil, seasonID: nil, quality: .original, route: .original,
                                     mediaSourceID: "src", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: t0)
            m.transition(to: .downloading)
            m.transition(to: .complete)
            let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"X","Name":"x","Type":"Movie"}"#.utf8))
            let src = try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"src"}"#.utf8))
            try store.create(m, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src))
        }
        store.activate(a)

        let gate = TestGate()
        let service = GatedUserDataService(gate: gate)
        let sync = DownloadProgressSync(store: store, service: service, userID: "a")
        let run = Task { await sync.run() }
        await gate.arrival(1)
        store.activate(b)
        gate.open()
        await run.value

        #expect(store.item("X")?.manifest.progress.positionTicks == 0)
        #expect(store.manifest(serverID: "s", userID: "b", itemID: "X")?.progress.positionTicks == 0)
        #expect(store.manifest(serverID: "s", userID: "a", itemID: "X")?.progress.positionTicks == 0)
    }
}

@MainActor
private final class ServiceBox {
    var current: JellyfinPlaybackServiceProtocol
    init(_ service: JellyfinPlaybackServiceProtocol) { current = service }
}

private final class GatedUserDataService: UserItemDataServing, @unchecked Sendable {
    let gate: TestGate
    init(gate: TestGate) { self.gate = gate }
    func userData(itemID: String, userID: String) async throws -> UserItemData {
        await gate.pass()
        return try JSONDecoder().decode(
            UserItemData.self,
            from: Data(#"{"PlaybackPositionTicks":777,"Played":true,"LastPlayedDate":"2027-01-15T09:00:00.0000000Z"}"#.utf8))
    }
    func updateUserData(itemID: String, userID: String, positionTicks: Int64, played: Bool, lastPlayed: Date) async throws {}
}
