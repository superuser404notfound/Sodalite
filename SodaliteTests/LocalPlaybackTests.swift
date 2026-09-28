import Foundation
import Testing
import AetherEngine
@testable import Sodalite

@MainActor
struct LocalPlaybackTests {
    private func downloaded(route: DownloadRoute, position: Int64 = 0, id: String = "ep-1",
                            season: Int = 1, index: Int = 1) -> DownloadedItem {
        let item = try! JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"E","Type":"Episode","SeriesId":"s","SeasonId":"se\#(season)","ParentIndexNumber":\#(season),"IndexNumber":\#(index),"RunTimeTicks":36000000000}"#.utf8))
        let source = try! JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"src","Container":"mkv","Bitrate":30000000,"MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"},{"Index":1,"Type":"Audio","Codec":"aac","Language":"ger"},{"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"ger"}]}"#.utf8))
        var manifest = DownloadManifest(itemID: id, seriesID: "s", seasonID: "se\(season)", quality: route == .original ? .original : .mbps4,
                                        route: route, mediaSourceID: "src", audioStreamIndex: nil, playSessionID: nil,
                                        state: .complete, createdAt: Date())
        manifest.mediaFileName = "media.mkv"
        manifest.subtitleFiles = [3: "sub-3.srt"]
        manifest.progress.positionTicks = position
        return DownloadedItem(manifest: manifest, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: source),
                              directory: URL(fileURLWithPath: "/dl/\(id)"))
    }

    @Test func aTranscodeTreatsEmbeddedTextAsSidecar() {
        let plan = LocalPlaybackPlan.make(downloaded(route: .transcode), startFromBeginning: false)!
        #expect(plan.url == URL(fileURLWithPath: "/dl/ep-1/media.mkv"))
        #expect(plan.subtitleMethod == .transcode)
        let subs = PlayerViewModel.externalSubtitleDescriptors(streams: plan.source.mediaStreams!.filter { $0.type == .subtitle },
                                                               playMethod: plan.subtitleMethod) { _ in URL(fileURLWithPath: "/dl/ep-1/sub-3.srt") }
        #expect(subs.descriptors.map(\.url) == [URL(fileURLWithPath: "/dl/ep-1/sub-3.srt")])
    }

    @Test func anOriginalReadsEmbeddedTracksFromTheFile() {
        let plan = LocalPlaybackPlan.make(downloaded(route: .original), startFromBeginning: false)!
        #expect(plan.subtitleMethod == .directPlay)
    }

    @Test func resumesFromTheManifestUnlessToldOtherwise() {
        #expect(LocalPlaybackPlan.make(downloaded(route: .original, position: 900), startFromBeginning: false)?.startTicks == 900)
        #expect(LocalPlaybackPlan.make(downloaded(route: .original, position: 900), startFromBeginning: true)?.startTicks == nil)
        #expect(LocalPlaybackPlan.make(downloaded(route: .original, position: 0), startFromBeginning: false)?.startTicks == nil)
    }

    @Test func aLocalSessionOffersNoServerFeatures() {
        let service = RecordingPlaybackService()
        let d = downloaded(route: .original)
        let vm = PlayerViewModel(item: d.snapshot.item, startFromBeginning: false, playbackService: service, userID: "u",
                                 preferences: PlaybackPreferences(store: UserDefaults(suiteName: "local-\(UUID())")!),
                                 localDownload: d)
        #expect(vm.isLocalSession)
        #expect(!vm.supportsQualityChoice)
        #expect(!vm.supportsSubtitleSearch)
    }

    @Test func aLocalSessionNeverAsksForPlaybackInfo() async {
        let service = RecordingPlaybackService()
        let d = downloaded(route: .original)
        let vm = PlayerViewModel(item: d.snapshot.item, startFromBeginning: false, playbackService: service, userID: "u",
                                 preferences: PlaybackPreferences(store: UserDefaults(suiteName: "local-\(UUID())")!),
                                 localDownload: d)
        await vm.startPlayback()   // the file does not exist, so load fails; what matters is what was asked
        #expect(service.playbackInfoRequests.isEmpty)
        vm.stopPlayback()
    }

    @Test func nextDownloadedEpisodeCrossesSeasons() {
        let current = downloaded(route: .original, id: "e1", season: 1, index: 9)
        let pool = [downloaded(route: .original, id: "e2", season: 2, index: 1),
                    downloaded(route: .original, id: "e0", season: 1, index: 8),
                    downloaded(route: .original, id: "e3", season: 2, index: 2)]
        #expect(PlayerViewModel.nextDownloadedEpisode(after: current.snapshot.item, in: pool)?.id == "e2")
        #expect(PlayerViewModel.nextDownloadedEpisode(after: pool[2].snapshot.item, in: pool) == nil)
    }

    @Test func progressLandsInTheManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LP-\(UUID().uuidString)")
        let store = DownloadStore(paths: DownloadPaths(root: root))
        store.activate(ProfileKey(serverID: "s", userID: "u"))
        let d = downloaded(route: .original)
        let created = try store.create(d.manifest, snapshot: d.snapshot)
        let vm = PlayerViewModel(item: d.snapshot.item, startFromBeginning: false, playbackService: RecordingPlaybackService(), userID: "u",
                                 preferences: PlaybackPreferences(store: UserDefaults(suiteName: "local-\(UUID())")!),
                                 localDownload: created, downloadStore: store)
        vm.recordLocalProgress(positionTicks: 1234, played: false)
        #expect(store.item("ep-1")?.manifest.progress.positionTicks == 1234)
        #expect(store.item("ep-1")?.manifest.progress.lastPlayed != nil)
    }
}
