import Foundation
import Testing
@testable import Sodalite

/// Sodalite#100: an ATSC 3.0 channel's AC-4 audio has no decoder anywhere in this stack, so the tune
/// used to sit in the tuning indicator until the viewer backed out. The refusal is a decision about
/// codec strings the server already handed us, so it is a pure function and these hold it.
///
/// The two spelling traps are the reason this is not a string comparison: Jellyfin copies a tuner
/// channel's audio codec verbatim out of the HDHomeRun's `lineup.json` (which reports "AC3", so
/// presumably "AC4"), while a probed source carries ffprobe's lowercase name, and the same tuner
/// channel reports index -1 for every stream.
@Suite("Live audio support")
struct LiveAudioSupportTests {

    private func stream(_ type: MediaStreamType, codec: String?, index: Int = -1) -> MediaStream {
        MediaStream(index: index, type: type, codec: codec, language: nil,
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: nil, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    private func audio(_ codec: String?, index: Int = -1) -> MediaStream {
        stream(.audio, codec: codec, index: index)
    }

    // MARK: - Refusal

    @Test("an AC-4 only channel is refused")
    func ac4OnlyIsRefused() {
        #expect(LiveAudioSupport.verdict(for: [stream(.video, codec: "hevc"), audio("ac4")])
            == .noDecodableAudio(.ac4))
    }

    @Test("the tuner's own spelling is the one that actually arrives", arguments: [
        "AC4", "AC-4", "ac-4", "Ac4", " ac4 ",
    ])
    func tunerSpellingsMatch(_ codec: String) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .noDecodableAudio(.ac4))
    }

    @Test("every MPEG-H spelling is refused", arguments: [
        "mpegh_3d_audio", "MPEGH", "mpegh3da", "mhm1", "mha1",
    ])
    func mpeghSpellingsMatch(_ codec: String) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .noDecodableAudio(.mpegH))
    }

    @Test("several undecodable tracks are still one refusal, named after the first")
    func severalUndecodableTracks() {
        #expect(LiveAudioSupport.verdict(for: [audio("ac4", index: 1), audio("mhm1", index: 3)])
            == .noDecodableAudio(.ac4))
    }

    // MARK: - Proceeding, which is the default the denylist has to fall back to

    @Test("one decodable track beside AC-4 plays")
    func mixedTracksProceed() {
        #expect(LiveAudioSupport.verdict(for: [audio("ac4"), audio("ac3")]) == .mayHaveAudio)
    }

    @Test("a source that named no audio at all is the engine's call")
    func noAudioReported() {
        #expect(LiveAudioSupport.verdict(for: [stream(.video, codec: "hevc")]) == .noAudioReported)
        #expect(LiveAudioSupport.verdict(for: []) == .noAudioReported)
        #expect(LiveAudioSupport.verdict(for: nil) == .noAudioReported)
    }

    @Test("an empty or missing codec string is not a refusal", arguments: [nil, "", "   "])
    func emptyCodecProceeds(_ codec: String?) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .mayHaveAudio)
    }

    @Test("ordinary broadcast audio is untouched", arguments: [
        "ac3", "eac3", "aac", "mp2", "AC3", "aac_latm", "opus", "dts",
    ])
    func decodableCodecsProceed(_ codec: String) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .mayHaveAudio)
    }

    @Test("a codec nobody enumerated proceeds rather than being refused by omission")
    func unknownCodecProceeds() {
        #expect(LiveAudioSupport.verdict(for: [audio("some_future_codec")]) == .mayHaveAudio)
    }

    @Test("a video stream carrying an unplayable name is not an audio verdict")
    func videoStreamIsIgnored() {
        #expect(LiveAudioSupport.verdict(for: [stream(.video, codec: "ac4")]) == .noAudioReported)
    }

    // MARK: - The diagnostic line, which is what answers the next report

    @Test("the log line keeps the server's raw spelling and index")
    func logLineKeepsRawSpelling() {
        #expect(LiveAudioSupport.logLine(for: [stream(.video, codec: "hevc"), audio("AC4")],
                                         serverOffersAudioReencode: false)
            == "[Live] audio streams: -1=AC4 verdict=noDecodableAudio(AC-4) decision=refuse")
    }

    @Test("a probed source's indices survive")
    func logLineProbedIndices() {
        #expect(LiveAudioSupport.logLine(for: [audio("ac4", index: 1), audio("ac4", index: 3)],
                                         serverOffersAudioReencode: false)
            == "[Live] audio streams: 1=ac4 3=ac4 verdict=noDecodableAudio(AC-4) decision=refuse")
    }

    @Test("a channel the server said nothing about says so")
    func logLineNoAudio() {
        #expect(LiveAudioSupport.logLine(for: [stream(.video, codec: "hevc")], serverOffersAudioReencode: false)
            == "[Live] audio streams: none reported")
    }

    @Test("a healthy channel is logged as checked, not as silence")
    func logLineHealthy() {
        #expect(LiveAudioSupport.logLine(for: [audio("ac3", index: 1)], serverOffersAudioReencode: false)
            == "[Live] audio streams: 1=ac3 verdict=mayHaveAudio")
    }

    @Test("an empty codec is visible in the line rather than blank")
    func logLineEmptyCodec() {
        #expect(LiveAudioSupport.logLine(for: [audio(nil, index: 2)], serverOffersAudioReencode: false)
            == "[Live] audio streams: 2=? verdict=mayHaveAudio")
    }

    // MARK: - The sentence the viewer reads

    /// The format name is a `%@` argument, so a catalog key without the substitution would ship a
    /// message that names no codec at all.
    @Test("the refusal names the format it refused")
    func refusalNamesTheFormat() {
        let message = ErrorText.user(for: PlayerEngineError.liveAudioUnsupported(codec: "AC-4"))
        #expect(message.contains("AC-4"))
        #expect(!message.contains("%@"))
        #expect(message != ErrorText.unexpected)
    }

    /// The permission refusal points at the fix, so it must not read as the hopeless one.
    @Test("the permission refusal names the format and differs from the hopeless one")
    func permissionRefusalNamesTheFormat() {
        let message = ErrorText.user(for: PlayerEngineError.liveAudioNeedsServerTranscoding(codec: "AC-4"))
        #expect(message.contains("AC-4"))
        #expect(!message.contains("%@"))
        #expect(message != ErrorText.user(for: PlayerEngineError.liveAudioUnsupported(codec: "AC-4")))
        #expect(PlayerEngineError.liveAudioNeedsServerTranscoding(codec: "AC-4").isLiveAudioRefusal)
    }

    @Test("both display names survive the round trip", arguments: [
        LiveAudioSupport.UnplayableCodec.ac4, .mpegH,
    ])
    func displayNamesReachTheMessage(_ codec: LiveAudioSupport.UnplayableCodec) {
        #expect(ErrorText.user(for: PlayerEngineError.liveAudioUnsupported(codec: codec.displayName))
            .contains(codec.displayName))
    }

    // MARK: - The server's re-encode, which is the only route to sound

    /// jellyfin-ffmpeg has carried an AC-4 decoder since v6.0.1-8 (jellyfin-ffmpeg#387, merged
    /// 2024-07-16, which is also why #128 was closed the same day), so a server can make this
    /// channel audible even though nothing on this device decodes the original. Refusing on the
    /// codec alone cut off the one route home, and the route ranking next door was already built to
    /// take it: liveTranscodeIsRealReencode counts an audio reason.
    @Test("an AC-4 channel the server re-encodes is played, not refused")
    func serverReencodeIsPlayed() {
        #expect(LiveAudioSupport.decision(for: [audio("AC4")], serverOffersAudioReencode: true)
            == .serverReencodeRequired(.ac4))
    }

    @Test("an AC-4 channel no server will re-encode is still refused")
    func withoutServerHelpItIsRefused() {
        #expect(LiveAudioSupport.decision(for: [audio("AC4")], serverOffersAudioReencode: false)
            == .refuse(.ac4))
    }

    /// The offer is not a reason on its own: a channel whose sound this device decodes keeps every
    /// route it had, including the tuner file the ranking prefers.
    @Test("a decodable soundtrack is never pushed onto the server for our sake")
    func decodableAudioProceeds() {
        #expect(LiveAudioSupport.decision(for: [audio("ac3")], serverOffersAudioReencode: true)
            == .proceed)
    }

    @Test("a channel with no audio named proceeds either way", arguments: [true, false])
    func noAudioProceeds(_ offered: Bool) {
        #expect(LiveAudioSupport.decision(for: [stream(.video, codec: "hevc")],
                                          serverOffersAudioReencode: offered) == .proceed)
    }

    @Test("MPEG-H takes the same route out")
    func mpeghUsesTheServerToo() {
        #expect(LiveAudioSupport.decision(for: [audio("mhm1")], serverOffersAudioReencode: true)
            == .serverReencodeRequired(.mpegH))
    }

    /// The raw tuner stream and the provider's own playlist both carry the original soundtrack, so
    /// the moment the server's re-encode is the reason we are still here, those two routes are
    /// silence. Only that case may skip them.
    @Test("only the server re-encode gives up the routes that carry the original")
    func onlyServerReencodeSkipsDirect() {
        #expect(LiveAudioSupport.decision(for: [audio("AC4")], serverOffersAudioReencode: true)
            .requiresServerReencode)
        #expect(!LiveAudioSupport.decision(for: [audio("ac3")], serverOffersAudioReencode: true)
            .requiresServerReencode)
        #expect(!LiveAudioSupport.decision(for: [audio("AC4")], serverOffersAudioReencode: false)
            .requiresServerReencode)
    }

    @Test("the line says which way the decision went, since the codec alone no longer decides")
    func logLineNamesTheServerRoute() {
        #expect(LiveAudioSupport.logLine(for: [audio("AC4")], serverOffersAudioReencode: true)
            == "[Live] audio streams: -1=AC4 verdict=noDecodableAudio(AC-4) decision=serverReencode")
    }

    // MARK: - The second pass, taken once a refusal is on the table (#100 round 3)

    /// Why the first answer is not the last word: Jellyfin never compares a tuner channel's audio
    /// codec against the profile at all. The lineup-derived stream carries no `IsDefault`, every
    /// user has `PlayDefaultAudioTrack` on by default, and StreamBuilder then narrows its candidate
    /// audio streams to the default ones and finds none, so the comparison is skipped and the
    /// verdict comes back DirectPlay. That is the one answer carrying neither a TranscodingUrl nor
    /// a reason, which is exactly the shape that used to read as "no offer, refuse".
    ///
    /// The same source, asked again with direct play off, has to go down the transcode path, where
    /// the soundtrack IS looked at. Nothing here changes the codec, only what the server was
    /// allowed to answer.
    @Test("the same AC-4 source is refused on the first answer and playable on the second")
    func secondPassTurnsARefusalIntoARoute() {
        let streams = [stream(.video, codec: "hevc"), audio("ac4")]
        #expect(LiveAudioSupport.decision(for: streams, serverOffersAudioReencode: false)
            == .refuse(.ac4))
        #expect(LiveAudioSupport.decision(for: streams, serverOffersAudioReencode: true)
            == .serverReencodeRequired(.ac4))
    }

    /// Two lines for one tune otherwise read as two tunes, and the pair is the whole evidence a
    /// retest on such a channel can carry back.
    @Test("the second answer names itself as the second answer")
    func logLineMarksTheSecondPass() {
        #expect(LiveAudioSupport.logLine(for: [audio("ac4")], serverOffersAudioReencode: true,
                                         pass: "noDirectPlay")
            == "[Live] audio streams: -1=ac4 verdict=noDecodableAudio(AC-4) decision=serverReencode"
            + " pass=noDirectPlay")
    }

    /// The marker has to survive the branch that returns early, or a server that names no audio at
    /// all on the second pass logs a line indistinguishable from the first.
    @Test("a second answer that names no audio is still marked")
    func logLineMarksTheSecondPassWithoutAudio() {
        #expect(LiveAudioSupport.logLine(for: [stream(.video, codec: "hevc")],
                                         serverOffersAudioReencode: false, pass: "noDirectPlay")
            == "[Live] audio streams: none reported pass=noDirectPlay")
    }

    @Test("an ordinary tune carries no marker")
    func logLineUnmarkedByDefault() {
        #expect(!LiveAudioSupport.logLine(for: [audio("ac3")], serverOffersAudioReencode: false)
            .contains("pass="))
    }

}
