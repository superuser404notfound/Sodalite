import Foundation
import Testing
@testable import Sodalite

/// Sodalite#70: a tuner-backed live channel is read from Jellyfin's own buffered tuner stream instead
/// of the static route that makes the server spawn a redundant copy-remux. The URL for that read comes
/// out of `MediaSource.Path`, which the server builds from its LOCAL bind address, so the host in it is
/// unusable for anyone not on that LAN. Only the server-relative part may survive.
@Suite("Live tuner-file stream URL")
@MainActor
struct LiveTunerStreamURLTests {

    private func service(baseURL: String, token: String? = "tok") -> JellyfinPlaybackService {
        let client = JellyfinClient()
        client.baseURL = URL(string: baseURL)
        client.accessToken = token
        return JellyfinPlaybackService(client: client)
    }

    // MARK: - What counts as the route

    @Test("a tuner MediaSource.Path yields its server-relative part")
    func acceptsTunerPath() {
        let relative = JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(relative == "/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
    }

    @Test("a base path baked into the server's local URL is dropped, ours is spliced back on")
    func dropsServerLocalBasePath() {
        let relative = JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/jellyfin/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(relative == "/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
    }

    @Test("a provider URL is not this route")
    func rejectsProviderURL() {
        let relative = JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "https://iptv.example/live/user/pass/42.ts")
        #expect(relative == nil)
    }

    @Test("a local file path is not this route")
    func rejectsFilePath() {
        #expect(JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "/media/tv/channel.ts") == nil)
        #expect(JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "file:///media/tv/channel.ts") == nil)
    }

    @Test("a VOD stream route is not this route")
    func rejectsVideosRoute() {
        let relative = JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/Videos/abc/stream.ts")
        #expect(relative == nil)
    }

    @Test("a truncated route with no stream id or file name is rejected")
    func rejectsTruncatedRoute() {
        #expect(JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/") == nil)
        #expect(JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2") == nil)
        #expect(JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/") == nil)
    }

    @Test("a query on the source path is carried through")
    func keepsQuery() {
        let relative = JellyfinPlaybackService.liveStreamFileRelativePath(
            fromSourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?x=1")
        #expect(relative == "/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?x=1")
    }

    // MARK: - Re-anchoring, which is the whole regression risk

    @Test("the server's LAN host is discarded for the URL the client is actually connected on")
    func reanchorsOnClientBaseURL() {
        let url = service(baseURL: "https://jf.example.com")
            .buildLiveStreamFileURL(
                sourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(url?.absoluteString
            == "https://jf.example.com/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?api_key=tok&ApiKey=tok")
    }

    @Test("a reverse-proxy subpath on our base URL survives")
    func keepsReverseProxySubpath() {
        let url = service(baseURL: "https://jf.example.com/jellyfin")
            .buildLiveStreamFileURL(
                sourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(url?.absoluteString
            == "https://jf.example.com/jellyfin/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?api_key=tok&ApiKey=tok")
    }

    @Test("a non-standard port on our base URL survives")
    func keepsPort() {
        let url = service(baseURL: "http://10.0.0.2:8920")
            .buildLiveStreamFileURL(
                sourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(url?.absoluteString
            == "http://10.0.0.2:8920/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?api_key=tok&ApiKey=tok")
    }

    @Test("an existing query gets the token appended, not replaced")
    func appendsTokenToExistingQuery() {
        let url = service(baseURL: "https://jf.example.com")
            .buildLiveStreamFileURL(
                sourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?x=1")
        #expect(url?.absoluteString
            == "https://jf.example.com/LiveTv/LiveStreamFiles/8a26baf2/stream.ts?x=1&api_key=tok&ApiKey=tok")
    }

    @Test("no session token still yields the URL: the route carries no authorization policy")
    func worksWithoutToken() {
        let url = service(baseURL: "https://jf.example.com", token: nil)
            .buildLiveStreamFileURL(
                sourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(url?.absoluteString
            == "https://jf.example.com/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
    }

    @Test("no base URL means no URL")
    func requiresBaseURL() {
        let client = JellyfinClient()
        client.accessToken = "tok"
        let url = JellyfinPlaybackService(client: client).buildLiveStreamFileURL(
            sourcePath: "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")
        #expect(url == nil)
    }
}
