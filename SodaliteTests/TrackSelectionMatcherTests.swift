import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Remembered picks travel as language/descriptor signatures, never as stream indices:
/// indices are unstable across the episodes of a series. Language equality is a hard
/// filter so a remembered German track can never resolve to an English one.
@MainActor
struct TrackSelectionMatcherTests {

    private func sub(index: Int, codec: String? = "subrip", lang: String? = "ger",
                     title: String? = nil, forced: Bool? = nil,
                     external: Bool = false) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: forced,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    private func audio(id: Int, codec: String = "eac3", lang: String? = "ger",
                       name: String = "German", channels: Int = 6,
                       commentary: Bool = false, described: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: name, codec: codec, language: lang, channels: channels,
                  bitrate: 0, isDefault: false, isForced: false, isHearingImpaired: false,
                  isCommentary: commentary, isVisualImpaired: described, isAtmos: false, assHeader: nil)
    }

    // MARK: - Signatures

    @Test("a subtitle signature captures language, flags, codec and descriptor")
    func subtitleSignature() {
        let signature = TrackSelectionMatcher.subtitleSignature(
            sub(index: 3, codec: "SUBRIP", lang: "ger", title: "German (SDH)"))
        #expect(signature.language == "ger")
        #expect(signature.isForced == false)
        #expect(signature.isExternal == false)
        #expect(signature.codec == "subrip")
        #expect(signature.descriptor == "sdh")
        #expect(signature.channels == nil)
    }

    @Test("an audio signature captures channels and the commentary descriptor")
    func audioSignature() {
        let signature = TrackSelectionMatcher.audioSignature(
            audio(id: 2, name: "Director Commentary", channels: 2, commentary: true))
        #expect(signature.language == "ger")
        #expect(signature.codec == "eac3")
        #expect(signature.channels == 2)
        #expect(signature.descriptor == "commentary")
    }

    // MARK: - Subtitle matching

    @Test("an exact signature wins over a same-language sibling")
    func exactSubtitleMatch() {
        let streams = [sub(index: 2, codec: "ass", lang: "ger"),
                       sub(index: 3, codec: "subrip", lang: "ger", title: "German (SDH)"),
                       sub(index: 4, codec: "subrip", lang: "eng")]
        let signature = TrackSelectionMatcher.subtitleSignature(streams[1])
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams)?.index == 3)
    }

    @Test("a different language never matches")
    func subtitleLanguageIsAHardFilter() {
        let signature = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "ger"))
        let streams = [sub(index: 2, lang: "eng"), sub(index: 5, lang: "fre")]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams) == nil)
    }

    @Test("language codes in different ISO forms still match")
    func subtitleLanguageSynonyms() {
        let signature = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "ger"))
        let streams = [sub(index: 9, codec: "subrip", lang: "de")]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams)?.index == 9)
    }

    @Test("a same-language track is taken when codec and descriptor differ")
    func subtitleFallsBackWithinLanguage() {
        let signature = TrackSelectionMatcher.subtitleSignature(
            sub(index: 3, codec: "subrip", lang: "ger", title: "German (SDH)"))
        let streams = [sub(index: 7, codec: "ass", lang: "ger")]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams)?.index == 7)
    }

    @Test("forced equality outranks codec equality")
    func subtitleForcedOutranksCodec() {
        let signature = TrackSelectionMatcher.subtitleSignature(
            sub(index: 3, codec: "subrip", lang: "ger", forced: true))
        let streams = [sub(index: 4, codec: "subrip", lang: "ger", forced: false),
                       sub(index: 5, codec: "ass", lang: "ger", forced: true)]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams)?.index == 5)
    }

    /// Vincent, 2026-09-25: forced lines only and every line are different choices, so a
    /// remembered forced pick never resolves to the full track. Audit 2026-09-25 PLAYER-PERIPHERY-5.
    @Test("a remembered forced track never resolves to a full one of the same language")
    func subtitleForcedIsAHardFilter() {
        let signature = TrackSelectionMatcher.subtitleSignature(
            sub(index: 3, lang: "eng", forced: true))
        let streams = [sub(index: 4, lang: "eng", forced: false),
                       sub(index: 5, lang: "eng", title: "English (SDH)")]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams) == nil)
    }

    @Test("a remembered full track may still take a forced one when nothing else is there")
    func subtitleFullMayTakeForced() {
        let signature = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "eng"))
        let streams = [sub(index: 6, lang: "eng", forced: true)]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams)?.index == 6)
    }

    @Test("an equal-scoring tie breaks on the lowest stream index")
    func subtitleTieBreak() {
        let signature = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "ger"))
        let streams = [sub(index: 8, lang: "ger"), sub(index: 6, lang: "ger")]
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: streams)?.index == 6)
    }

    @Test("an unknown-language signature matches unknown-language candidates only")
    func subtitleUnknownLanguage() {
        let signature = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "und"))
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: [sub(index: 4, lang: nil)])?.index == 4)
        #expect(TrackSelectionMatcher.matchSubtitle(signature, in: [sub(index: 4, lang: "ger")]) == nil)
    }

    // MARK: - Audio matching

    @Test("channel count outranks codec when picking among same-language audio")
    func audioPrefersChannelCount() {
        let signature = TrackSelectionMatcher.audioSignature(audio(id: 1, codec: "eac3", channels: 6))
        let tracks = [audio(id: 2, codec: "eac3", channels: 2),
                      audio(id: 3, codec: "dts", channels: 6)]
        #expect(TrackSelectionMatcher.matchAudio(signature, in: tracks)?.id == 3)
    }

    @Test("a remembered commentary track is not replaced by the main mix")
    func audioPrefersCommentary() {
        let signature = TrackSelectionMatcher.audioSignature(
            audio(id: 1, channels: 2, commentary: true))
        let tracks = [audio(id: 4, channels: 6, commentary: false),
                      audio(id: 5, channels: 2, commentary: true)]
        #expect(TrackSelectionMatcher.matchAudio(signature, in: tracks)?.id == 5)
    }

    // MARK: - Audio description (AetherEngine#919)

    @Test("a remembered main mix never resolves to an audio description, even one with its channel count")
    func mainMixNeverAdoptsDescribed() {
        let signature = TrackSelectionMatcher.audioSignature(audio(id: 1, channels: 6))
        let tracks = [audio(id: 2, channels: 6, described: true), audio(id: 3, channels: 2)]
        #expect(TrackSelectionMatcher.matchAudio(signature, in: tracks)?.id == 3)
    }

    @Test("a remembered audio description resolves to this title's described track or to nothing")
    func describedOnlyAdoptsDescribed() {
        let signature = TrackSelectionMatcher.audioSignature(audio(id: 1, channels: 6, described: true))
        #expect(signature.descriptor == TrackSelectionMatcher.describedDescriptor)
        let tracks = [audio(id: 2, channels: 6), audio(id: 3, channels: 2, described: true)]
        #expect(TrackSelectionMatcher.matchAudio(signature, in: tracks)?.id == 3)
        #expect(TrackSelectionMatcher.matchAudio(signature, in: [audio(id: 2, channels: 6)]) == nil)
    }

    @Test("the system setting takes the described track of the picked language, never another language's")
    func systemSettingStaysInLanguage() {
        let tracks = [audio(id: 1, lang: "eng", channels: 6), audio(id: 2, lang: "ger", channels: 6, described: true),
                      audio(id: 3, lang: "eng", channels: 2, described: true),
                      audio(id: 4, lang: "eng", channels: 6, described: true)]
        #expect(TrackSelectionMatcher.describedAudio(for: tracks[0], in: tracks)?.id == 4)
        #expect(TrackSelectionMatcher.describedAudio(for: tracks[3], in: tracks) == nil)
        #expect(TrackSelectionMatcher.describedAudio(for: tracks[0], in: Array(tracks.prefix(2))) == nil)
        #expect(TrackSelectionMatcher.describedAudio(for: nil, in: tracks) == nil)
    }

    // MARK: - Plan

    @Test("no entry falls through to the app's automatic resolution")
    func planWithoutEntry() {
        let plan = TrackSelectionMatcher.plan(entry: nil, subtitleStreams: [sub(index: 2)], audioTracks: [audio(id: 1)])
        #expect(plan == TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: nil))
    }

    @Test("a remembered off stays off")
    func planRemembersOff() {
        let entry = TrackMemoryEntry(subtitle: .off, audio: nil, updatedAt: Date(timeIntervalSince1970: 1))
        let plan = TrackSelectionMatcher.plan(entry: entry, subtitleStreams: [sub(index: 2)], audioTracks: [])
        #expect(plan.subtitle == .off)
    }

    @Test("a remembered track resolves to this title's stream index")
    func planResolvesTrack() {
        let remembered = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "ger"))
        let entry = TrackMemoryEntry(subtitle: .track(remembered), audio: nil,
                                     updatedAt: Date(timeIntervalSince1970: 1))
        let plan = TrackSelectionMatcher.plan(entry: entry,
                                              subtitleStreams: [sub(index: 11, lang: "ger")],
                                              audioTracks: [])
        #expect(plan.subtitle == .select(streamIndex: 11))
    }

    @Test("a remembered track that this title does not have falls through")
    func planFallsThroughOnMiss() {
        let remembered = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "ger"))
        let entry = TrackMemoryEntry(subtitle: .track(remembered), audio: nil,
                                     updatedAt: Date(timeIntervalSince1970: 1))
        let plan = TrackSelectionMatcher.plan(entry: entry,
                                              subtitleStreams: [sub(index: 4, lang: "eng")],
                                              audioTracks: [])
        #expect(plan.subtitle == .fallThrough)
    }

    @Test("a remembered forced track with no forced counterpart plans subtitles off")
    func planForcedMissStaysOff() {
        let remembered = TrackSelectionMatcher.subtitleSignature(sub(index: 3, lang: "eng", forced: true))
        let entry = TrackMemoryEntry(subtitle: .track(remembered), audio: nil,
                                     updatedAt: Date(timeIntervalSince1970: 1))
        let missing = TrackSelectionMatcher.plan(
            entry: entry, subtitleStreams: [sub(index: 4, lang: "eng", forced: false)], audioTracks: [])
        #expect(missing.subtitle == .off)
        let present = TrackSelectionMatcher.plan(
            entry: entry,
            subtitleStreams: [sub(index: 4, lang: "eng", forced: false), sub(index: 7, lang: "eng", forced: true)],
            audioTracks: [])
        #expect(present.subtitle == .select(streamIndex: 7))
    }

    @Test("a remembered audio track is planned by engine track id")
    func planResolvesAudio() {
        let remembered = TrackSelectionMatcher.audioSignature(audio(id: 1, channels: 6))
        let entry = TrackMemoryEntry(subtitle: nil, audio: remembered,
                                     updatedAt: Date(timeIntervalSince1970: 1))
        let plan = TrackSelectionMatcher.plan(entry: entry, subtitleStreams: [],
                                              audioTracks: [audio(id: 9, channels: 6)])
        #expect(plan.audioTrackID == 9)
    }

    // MARK: - Pre-load audio

    private func audioStream(index: Int, codec: String, lang: String? = "eng",
                             title: String? = nil, channels: Int,
                             external: Bool = false) -> MediaStream {
        MediaStream(index: index, type: .audio, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: nil,
                    isExternal: external, height: nil, width: nil, channels: channels,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    /// BurgerMage27's file: TrueHD Atmos first, AC-3 and DTS-HD MA behind it, all English. The
    /// remembered DTS-HD track used to open as TrueHD and reload about three seconds in.
    private var discRemux: [MediaStream] {
        [MediaStream(index: 0, type: .video, codec: "hevc", language: nil, displayTitle: nil,
                     title: nil, isDefault: nil, isForced: nil, isExternal: false, height: 2160,
                     width: 3840, channels: nil, videoRange: nil, videoRangeType: nil,
                     averageFrameRate: nil, realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil),
         audioStream(index: 1, codec: "truehd", channels: 8),
         audioStream(index: 2, codec: "ac3", channels: 6),
         audioStream(index: 3, codec: "dts", channels: 8)]
    }

    @Test("a remembered second track of the same language resolves to its container index before load")
    func preloadPicksSameLanguageSibling() {
        let remembered = TrackSelectionMatcher.audioSignature(
            audio(id: 3, codec: "dts", lang: "eng", name: "English", channels: 8))
        let entry = TrackMemoryEntry(subtitle: nil, audio: remembered,
                                     updatedAt: Date(timeIntervalSince1970: 1))
        #expect(TrackSelectionMatcher.preloadAudioStreamIndex(entry: entry, mediaStreams: discRemux) == 3)
    }

    @Test("an external file numbered first shifts the Jellyfin index back to the container's")
    func preloadMapsPastExternalStreams() {
        let remembered = TrackSelectionMatcher.audioSignature(
            audio(id: 2, codec: "ac3", lang: "eng", name: "English", channels: 6))
        let entry = TrackMemoryEntry(subtitle: nil, audio: remembered,
                                     updatedAt: Date(timeIntervalSince1970: 1))
        let streams = [sub(index: 0, lang: "eng", external: true)]
            + discRemux.map { stream in
                MediaStream(index: stream.index + 1, type: stream.type, codec: stream.codec,
                            language: stream.language, displayTitle: nil, title: nil, isDefault: nil,
                            isForced: nil, isExternal: false, height: nil, width: nil,
                            channels: stream.channels, videoRange: nil, videoRangeType: nil,
                            averageFrameRate: nil, realFrameRate: nil, profile: nil, bitRate: nil,
                            dvProfile: nil)
            }
        #expect(TrackSelectionMatcher.preloadAudioStreamIndex(entry: entry, mediaStreams: streams) == 2)
    }

    @Test("nothing remembered, another language or a remembered description leaves the pick to the engine")
    func preloadDefersWhenItCannotDecide() {
        #expect(TrackSelectionMatcher.preloadAudioStreamIndex(entry: nil, mediaStreams: discRemux) == nil)

        let german = TrackSelectionMatcher.audioSignature(audio(id: 1, lang: "ger"))
        let germanEntry = TrackMemoryEntry(subtitle: nil, audio: german,
                                           updatedAt: Date(timeIntervalSince1970: 1))
        #expect(TrackSelectionMatcher.preloadAudioStreamIndex(entry: germanEntry, mediaStreams: discRemux) == nil)

        let described = TrackSelectionMatcher.audioSignature(
            audio(id: 4, lang: "eng", name: "English", channels: 2, described: true))
        let describedEntry = TrackMemoryEntry(subtitle: nil, audio: described,
                                              updatedAt: Date(timeIntervalSince1970: 1))
        #expect(TrackSelectionMatcher.preloadAudioStreamIndex(entry: describedEntry, mediaStreams: discRemux) == nil)
    }
}
