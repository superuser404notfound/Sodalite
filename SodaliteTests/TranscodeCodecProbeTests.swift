import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: whether a server encodes HEVC is an admin setting a client cannot read, but the master
/// playlist of a transcode names the codec Jellyfin would encode in, and building that playlist starts
/// no ffmpeg (`DynamicHlsHelper` only computes the streaming state). So the picker can know before the
/// first real transcode.
struct TranscodeCodecProbeTests {
    /// The master an iPhone received on 2026-09-28, with HEVC encoding allowed.
    private let hevcMaster = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=4000000,AVERAGE-BANDWIDTH=4000000,VIDEO-RANGE=SDR,CODECS="hvc1.2.4.L150.B0,ec-3",RESOLUTION=1920x1080,FRAME-RATE=23.976,SUBTITLES="subs"
    main.m3u8?DeviceId=x
    """

    @Test func aHEVCMasterReadsHEVC() {
        #expect(TranscodeCodecProbe.videoCodec(fromMaster: hevcMaster) == "hevc")
    }

    @Test func anH264MasterReadsH264() {
        let master = #"#EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720"#
        #expect(TranscodeCodecProbe.videoCodec(fromMaster: master) == "h264")
    }

    @Test func hev1CountsAsHEVCToo() {
        #expect(TranscodeCodecProbe.videoCodec(fromMaster: #"CODECS="hev1.1.6.L120.90,mp4a.40.2""#) == "hevc")
    }

    @Test func aMasterWithoutAVideoCodecReadsNothing() {
        #expect(TranscodeCodecProbe.videoCodec(fromMaster: #"CODECS="mp4a.40.2""#) == nil)
        #expect(TranscodeCodecProbe.videoCodec(fromMaster: "#EXTM3U") == nil)
    }

    @Test func theProbeRecordsWhatTheMasterSays() async throws {
        let service = RecordingPlaybackService()
        service.transcodingURLWhenUnpinned = "/videos/ep-1/master.m3u8?VideoCodec=hevc,h264"
        let memory = TranscodeCodecMemory(defaults: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
        let codec = await TranscodeCodecProbe.run(
            itemID: "ep-1", userID: "user", server: "jf.local", service: service, memory: memory,
            resolve: { URL(string: "https://jf.local\($0)") },
            fetch: { _ in self.hevcMaster })
        #expect(codec == "hevc")
        #expect(memory.encodesHEVC(server: "jf.local"))
        #expect(memory.knownCodec(server: "jf.local") == "hevc")
    }

    /// Once a server is known the probe spends no request on it.
    @Test func aKnownServerIsNotProbedAgain() async throws {
        let service = RecordingPlaybackService()
        let memory = TranscodeCodecMemory(defaults: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
        memory.record(server: "jf.local", deliveredCodec: "h264")
        _ = await TranscodeCodecProbe.run(
            itemID: "ep-1", userID: "user", server: "jf.local", service: service, memory: memory,
            resolve: { URL(string: "https://jf.local\($0)") }, fetch: { _ in self.hevcMaster })
        #expect(service.playbackInfoRequests.isEmpty)
    }
}
