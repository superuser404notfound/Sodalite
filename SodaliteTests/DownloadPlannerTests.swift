import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadPlannerTests {
    private let base = URL(string: "https://jf.example")!

    private func source(bitrate: Int?, transcodingUrl: String?) -> PlaybackMediaSource {
        let tc = transcodingUrl.map { #","TranscodingUrl":"\#($0)""# } ?? ""
        let br = bitrate.map { #","Bitrate":\#($0)"# } ?? ""
        let json = #"{"Id":"src","Container":"mkv","Size":9000000000\#(br)\#(tc),"MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"},{"Index":1,"Type":"Audio","Codec":"truehd","Language":"eng"},{"Index":2,"Type":"Audio","Codec":"ac3","Language":"ger"},{"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"ger"},{"Index":4,"Type":"Subtitle","Codec":"PGSSUB","Language":"eng"},{"Index":5,"Type":"Subtitle","Codec":"subrip","Language":"eng","IsExternal":true}]}"#
        return try! JSONDecoder().decode(PlaybackMediaSource.self, from: Data(json.utf8))
    }

    @Test func downloadProfileTranscodesToFragmentedProgressiveMP4() {
        let profile = DirectPlayProfile.downloadProfile(maxStreamingBitrate: 10_000_000)
        #expect(profile["MaxStreamingBitrate"] as? Int == 10_000_000)
        let video = (profile["TranscodingProfiles"] as? [[String: Any]])?.first { $0["Type"] as? String == "Video" }
        #expect(video?["Protocol"] as? String == "http")
        #expect(video?["Container"] as? String == "mp4")
        #expect(video?["Context"] as? String == "Streaming")
        #expect(video?["AudioCodec"] as? String == "aac")
    }

    @Test func originalUsesTheDownloadEndpoint() {
        let plan = DownloadPlanner.plan(itemID: "it", source: source(bitrate: 30_000_000, transcodingUrl: "/videos/it/stream.mp4?x=1"),
                                        quality: .original, runtimeTicks: 72_000_000_000, audioStreamIndex: nil, baseURL: base)
        #expect(plan.route == .original)
        #expect(plan.url.absoluteString == "https://jf.example/Items/it/Download")
        #expect(plan.expectedBytes == 9_000_000_000)
        #expect(plan.mediaFileExtension == "mkv")
    }

    @Test func aRungThatDoesNotBiteStaysOriginal() {
        let plan = DownloadPlanner.plan(itemID: "it", source: source(bitrate: 6_000_000, transcodingUrl: nil),
                                        quality: .mbps10, runtimeTicks: 72_000_000_000, audioStreamIndex: nil, baseURL: base)
        #expect(plan.route == .original)
    }

    @Test func aBitingRungUsesTheTranscodeWithoutTheToken() {
        let plan = DownloadPlanner.plan(itemID: "it", source: source(bitrate: 30_000_000, transcodingUrl: "/videos/it/stream.mp4?MediaSourceId=src&api_key=SECRET&AudioStreamIndex=2"),
                                        quality: .mbps4, runtimeTicks: 72_000_000_000, audioStreamIndex: 2, baseURL: base)
        #expect(plan.route == .transcode)
        #expect(plan.url.absoluteString.hasPrefix("https://jf.example/videos/it/stream.mp4?"))
        #expect(!plan.url.absoluteString.contains("SECRET"))
        #expect(plan.url.absoluteString.contains("AudioStreamIndex=2"))
        #expect(plan.mediaFileExtension == "mp4")
        // 4 Mbit/s for two hours
        #expect(plan.expectedBytes == Int64(3_600_000_000))
    }

    @Test func aBitingRungWithoutATranscodeUrlFallsBackToOriginal() {
        let plan = DownloadPlanner.plan(itemID: "it", source: source(bitrate: nil, transcodingUrl: nil),
                                        quality: .mbps4, runtimeTicks: 72_000_000_000, audioStreamIndex: nil, baseURL: base)
        #expect(plan.route == .original)
    }

    @Test func originalFetchesOnlyExternalTextSidecars() {
        let plan = DownloadPlanner.plan(itemID: "it", source: source(bitrate: 30_000_000, transcodingUrl: nil),
                                        quality: .original, runtimeTicks: nil, audioStreamIndex: nil, baseURL: base)
        #expect(plan.sidecarStreams.map(\.index) == [5])
        #expect(plan.localSource.mediaStreams?.count == 6)
    }

    @Test func transcodeKeepsOneAudioAndOnlyTextSubtitles() {
        let plan = DownloadPlanner.plan(itemID: "it", source: source(bitrate: 30_000_000, transcodingUrl: "/videos/it/stream.mp4"),
                                        quality: .mbps4, runtimeTicks: nil, audioStreamIndex: 2, baseURL: base)
        #expect(plan.sidecarStreams.map(\.index) == [3, 5])
        #expect(plan.localSource.mediaStreams?.map(\.index) == [0, 2, 3, 5])
    }

    @Test func estimates() {
        #expect(DownloadPlanner.estimatedBytes(quality: .original, sourceBitrate: 30_000_000, sourceSize: 123, runtimeTicks: 36_000_000_000) == 123)
        #expect(DownloadPlanner.estimatedBytes(quality: .mbps40, sourceBitrate: 30_000_000, sourceSize: 123, runtimeTicks: 36_000_000_000) == 123)
        #expect(DownloadPlanner.estimatedBytes(quality: .mbps2, sourceBitrate: 30_000_000, sourceSize: 123, runtimeTicks: 36_000_000_000) == Int64(900_000_000))
        #expect(DownloadPlanner.estimatedBytes(quality: .mbps2, sourceBitrate: 30_000_000, sourceSize: nil, runtimeTicks: nil) == nil)
    }

    @Test func spaceCheck() {
        let gb: Int64 = 1_073_741_824
        #expect(DownloadPlanner.refusesForSpace(estimate: 4 * gb, available: 4 * gb))
        #expect(!DownloadPlanner.refusesForSpace(estimate: 4 * gb, available: 5 * gb))
        #expect(!DownloadPlanner.refusesForSpace(estimate: nil, available: 1))
        #expect(!DownloadPlanner.refusesForSpace(estimate: 4 * gb, available: nil))
    }

    @Test func statusMapping() {
        #expect(DownloadPlanner.failure(forStatus: 200) == nil)
        #expect(DownloadPlanner.failure(forStatus: 206) == nil)
        #expect(DownloadPlanner.failure(forStatus: 401) == .unauthorized)
        #expect(DownloadPlanner.failure(forStatus: 403) == .notAllowed)
        #expect(DownloadPlanner.failure(forStatus: 400) == .notAllowed)
        #expect(DownloadPlanner.failure(forStatus: 500) == .server)
        #expect(DownloadPlanner.failure(forStatus: 404) == .server)
    }

    @Test func audioChoice() {
        let streams = source(bitrate: nil, transcodingUrl: nil).mediaStreams!
        #expect(DownloadPlanner.audioStreamIndex(preferredLanguage: "ger", streams: streams) == 2)
        #expect(DownloadPlanner.audioStreamIndex(preferredLanguage: "deu", streams: streams) == 2)
        #expect(DownloadPlanner.audioStreamIndex(preferredLanguage: nil, streams: streams) == 1)
        #expect(DownloadPlanner.audioStreamIndex(preferredLanguage: "jpn", streams: streams) == 1)
    }

    @Test func authorizedRequestCarriesTheHeaderAndNoToken() {
        let request = DownloadPlanner.authorizedRequest(url: URL(string: "https://jf.example/a?api_key=S&ApiKey=S&keep=1")!,
                                                        authorization: "MediaBrowser Token=\"S\"")
        #expect(request.url?.absoluteString == "https://jf.example/a?keep=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"S\"")
    }

    @Test func userDataEndpoints() {
        let get = JellyfinEndpoint.userItemData(itemID: "it", userID: "u")
        #expect(get.path == "/UserItems/it/UserData")
        #expect(get.method == .get)
        #expect(get.queryItems == [URLQueryItem(name: "userId", value: "u")])
        let post = JellyfinEndpoint.updateUserItemData(itemID: "it", userID: "u", payload: try! JSONValue(jsonObject: ["Played": true]))
        #expect(post.method == .post)
        #expect(post.path == "/UserItems/it/UserData")
    }
}
