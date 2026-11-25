import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// A track pick made on a detail page before playback (Sodalite#250). It stands in for the remembered
/// entry on the launch item's first load and nowhere else.
@MainActor
struct LaunchTrackPickTests {

    private let stamp = Date(timeIntervalSince1970: 1)

    private func audio(_ index: Int, codec: String, lang: String = "eng", channels: Int,
                       external: Bool = false) -> MediaStream {
        MediaStream(index: index, type: .audio, codec: codec, language: lang,
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: external, height: nil, width: nil, channels: channels,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    private func sub(_ index: Int, lang: String = "eng", external: Bool = false) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: "subrip", language: lang,
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    /// One external subtitle numbered first, so Jellyfin's index and the container's differ by one.
    private var streams: [MediaStream] {
        [sub(0, external: true), audio(1, codec: "truehd", channels: 8),
         audio(2, codec: "ac3", channels: 6), sub(3), sub(4, lang: "ger")]
    }

    private var german: TrackSignature {
        TrackSignature(language: "ger", isForced: false, isExternal: false, codec: "eac3",
                       descriptor: nil, channels: 6)
    }

    private func pick(audio: LaunchTrackPick.Audio? = nil,
                      subtitle: LaunchTrackPick.Subtitle? = nil) -> LaunchTrackPick {
        LaunchTrackPick(itemID: "e1", sourceID: "src-a", audio: audio, subtitle: subtitle)
    }

    private func ac3Pick() -> LaunchTrackPick.Audio {
        LaunchTrackPick.Audio(streamIndex: 2,
                              signature: TrackSelectionMatcher.audioSignature(streams[2], in: streams))
    }

    // MARK: - The entry it stands in for

    @Test func overridingReplacesOnlyPickedAxes() {
        let remembered = TrackMemoryEntry(subtitle: .off, audio: german, updatedAt: stamp)
        let english = TrackSelectionMatcher.subtitleSignature(streams[3])
        let entry = pick(subtitle: .track(streamIndex: 3, signature: english)).overriding(remembered, now: stamp)
        #expect(entry.audio == german)
        #expect(entry.subtitle == .track(english))
    }

    @Test func overridingWithoutMemoryBuildsEntry() {
        let entry = pick(audio: ac3Pick()).overriding(nil, now: stamp)
        #expect(entry.audio == ac3Pick().signature)
        #expect(entry.subtitle == nil)
    }

    @Test func subtitleOffPickBecomesOff() {
        let remembered = TrackMemoryEntry(subtitle: .track(german), audio: nil, updatedAt: stamp)
        #expect(pick(subtitle: .off).overriding(remembered, now: stamp).subtitle == .off)
    }

    // MARK: - Exact indices

    @Test func preloadUsesIndexOnlyForDirectPlayOfPickedSource() {
        let p = pick(audio: ac3Pick())
        #expect(p.preloadAudioIndex(playedSourceID: "src-a", isDirectPlay: true, mediaStreams: streams) == 1)
        #expect(p.preloadAudioIndex(playedSourceID: "src-b", isDirectPlay: true, mediaStreams: streams) == nil)
        #expect(p.preloadAudioIndex(playedSourceID: "src-a", isDirectPlay: false, mediaStreams: streams) == nil)
        #expect(p.preloadAudioIndex(playedSourceID: nil, isDirectPlay: true, mediaStreams: streams) == nil)
        #expect(pick().preloadAudioIndex(playedSourceID: "src-a", isDirectPlay: true, mediaStreams: streams) == nil)
    }

    @Test func pinningUsesSubtitleIndexForSameSourceEvenUnderTranscode() {
        let english = TrackSelectionMatcher.subtitleSignature(streams[3])
        let plan = TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: nil)
        let pinned = pick(subtitle: .track(streamIndex: 3, signature: english))
            .pinning(plan, playedSourceID: "src-a", isDirectPlay: false, mediaStreams: streams,
                     subtitleStreams: [streams[0], streams[3], streams[4]], engineAudioIDs: [0, 1])
        #expect(pinned.subtitle == .select(streamIndex: 3))
    }

    @Test func pinningUsesAudioIndexOnlyUnderDirectPlay() {
        let plan = TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: 0)
        let direct = pick(audio: ac3Pick())
            .pinning(plan, playedSourceID: "src-a", isDirectPlay: true, mediaStreams: streams, subtitleStreams: [], engineAudioIDs: [0, 1])
        #expect(direct.audioTrackID == 1)
        let transcode = pick(audio: ac3Pick())
            .pinning(plan, playedSourceID: "src-a", isDirectPlay: false, mediaStreams: streams, subtitleStreams: [], engineAudioIDs: [0, 1])
        #expect(transcode.audioTrackID == 0)
    }

    /// Jellyfin can list an audio stream the engine's probe did not (an unsupported codec); selecting
    /// an id the engine does not have would reload for nothing.
    @Test func pinningKeepsThePlanWhenTheEngineLacksTheTrack() {
        let plan = TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: 0)
        let pinned = pick(audio: ac3Pick())
            .pinning(plan, playedSourceID: "src-a", isDirectPlay: true, mediaStreams: streams,
                     subtitleStreams: [], engineAudioIDs: [0])
        #expect(pinned.audioTrackID == 0)
    }

    // MARK: - PlaybackInfo

    /// A transcode only carries the audio PlaybackInfo named, so the picked index has to go there.
    @Test func playbackInfoNamesThePickedAudioOfThePinnedSource() {
        #expect(pick(audio: ac3Pick()).playbackInfoAudioIndex(pinnedSourceID: "src-a") == 2)
        #expect(pick(audio: ac3Pick()).playbackInfoAudioIndex(pinnedSourceID: nil) == 2)
        #expect(pick(audio: ac3Pick()).playbackInfoAudioIndex(pinnedSourceID: "src-b") == nil)
        #expect(pick(subtitle: .off).playbackInfoAudioIndex(pinnedSourceID: "src-a") == nil)
    }

    // MARK: - What gets remembered

    @Test func anOffPickAppliedAsOffIsRemembered() {
        let plan = TrackSelectionPlan(subtitle: .off, audioTrackID: nil)
        #expect(pick(subtitle: .off).appliedSubtitle(plan, subtitleStreams: streams) == .off)
    }

    @Test func aTrackPickRemembersTheStreamThatWasSelected() {
        let english = TrackSelectionMatcher.subtitleSignature(streams[3])
        let plan = TrackSelectionPlan(subtitle: .select(streamIndex: 3), audioTrackID: nil)
        #expect(pick(subtitle: .track(streamIndex: 3, signature: english))
            .appliedSubtitle(plan, subtitleStreams: streams) == .track(english))
    }

    /// An unmatched forced pick becomes "off" in the plan; remembering that would store the opposite
    /// of what the viewer picked.
    @Test func anUnmatchedTrackPickRemembersNothing() {
        let forced = TrackSignature(language: "eng", isForced: true, isExternal: false, codec: "pgssub",
                                    descriptor: "forced", channels: nil)
        let off = TrackSelectionPlan(subtitle: .off, audioTrackID: nil)
        #expect(pick(subtitle: .track(streamIndex: 7, signature: forced)).appliedSubtitle(off, subtitleStreams: streams) == nil)
        let fallThrough = TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: nil)
        #expect(pick(subtitle: .track(streamIndex: 7, signature: forced)).appliedSubtitle(fallThrough, subtitleStreams: streams) == nil)
        #expect(pick(audio: ac3Pick()).appliedSubtitle(off, subtitleStreams: streams) == nil)
    }

    @Test func pinningIgnoresIndexOfAnotherSource() {
        let english = TrackSelectionMatcher.subtitleSignature(streams[3])
        let plan = TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: nil)
        let pinned = pick(audio: ac3Pick(), subtitle: .track(streamIndex: 3, signature: english))
            .pinning(plan, playedSourceID: "src-b", isDirectPlay: true, mediaStreams: streams,
                     subtitleStreams: [streams[3]], engineAudioIDs: [0, 1])
        #expect(pinned == plan)
    }

    @Test func pinningIgnoresMissingIndex() {
        let english = TrackSelectionMatcher.subtitleSignature(streams[3])
        let plan = TrackSelectionPlan(subtitle: .off, audioTrackID: nil)
        let pinned = pick(subtitle: .track(streamIndex: 9, signature: english))
            .pinning(plan, playedSourceID: "src-a", isDirectPlay: true, mediaStreams: streams,
                     subtitleStreams: [streams[3]], engineAudioIDs: [0, 1])
        #expect(pinned == plan)
    }

    @Test func pinningTurnsAnOffPickIntoOff() {
        let plan = TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: nil)
        let pinned = pick(subtitle: .off)
            .pinning(plan, playedSourceID: "src-b", isDirectPlay: false, mediaStreams: streams, subtitleStreams: [], engineAudioIDs: [0, 1])
        #expect(pinned.subtitle == .off)
    }

    // MARK: - In the player

    private func episode(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"show","RunTimeTicks":36000000000}"#.utf8))
    }

    private func makeViewModel(pick: LaunchTrackPick?, memory: TrackSelectionMemory? = nil,
                               remember: Bool = true) throws -> PlayerViewModel {
        let preferences = PlaybackPreferences(store: UserDefaults(suiteName: "test.launchpick.\(UUID())")!)
        preferences.rememberTrackSelections = remember
        return PlayerViewModel(
            item: try episode("e1"), startFromBeginning: false,
            playbackService: RecordingPlaybackService(), userID: "user",
            preferences: preferences, trackMemory: memory, launchTrackPick: pick)
    }

    @Test func pendingPickBelongsToTheLaunchItemOnly() throws {
        let vm = try makeViewModel(pick: pick(audio: ac3Pick()))
        #expect(vm.pendingLaunchTrackPick != nil)
        vm.resetSessionState(.itemSwitch(to: try episode("e2")))
        #expect(vm.pendingLaunchTrackPick == nil)
    }

    @Test func aPickForAnotherItemIsNeverPending() throws {
        let other = LaunchTrackPick(itemID: "e9", sourceID: "src-a", audio: ac3Pick(), subtitle: nil)
        #expect(try makeViewModel(pick: other).pendingLaunchTrackPick == nil)
    }

    @Test func pendingPickIsGoneOnceConsumed() throws {
        let vm = try makeViewModel(pick: pick(audio: ac3Pick()))
        vm.recordAppliedLaunchPick(audioTrack: nil, subtitle: nil)
        #expect(vm.pendingLaunchTrackPick == nil)
        vm.resetSessionState(.sameItemReload)
        #expect(vm.pendingLaunchTrackPick == nil)
    }

    @Test func pickIsRecordedLikeAnInPlayerPick() throws {
        let memory = TrackSelectionMemory(store: UserDefaults(suiteName: "test.launchpick.mem.\(UUID())")!)
        let vm = try makeViewModel(pick: pick(audio: ac3Pick(), subtitle: .off), memory: memory)
        let engineTrack = TrackSelectionMatcher.audioTrackInfo(streams[2], in: streams)
        vm.recordAppliedLaunchPick(audioTrack: engineTrack, subtitle: .off)
        let key = TrackSelectionMemory.scopeKey(userID: "user", itemID: "e1", seriesID: "show")
        #expect(memory.entry(for: key)?.audio == TrackSelectionMatcher.audioSignature(engineTrack))
        #expect(memory.entry(for: key)?.subtitle == .off)
    }

    @Test func pickIsNotRecordedWhenMemoryIsOff() throws {
        let memory = TrackSelectionMemory(store: UserDefaults(suiteName: "test.launchpick.off.\(UUID())")!)
        let vm = try makeViewModel(pick: pick(audio: ac3Pick()), memory: memory, remember: false)
        vm.recordAppliedLaunchPick(audioTrack: TrackSelectionMatcher.audioTrackInfo(streams[2], in: streams), subtitle: .off)
        #expect(memory.entries.isEmpty)
        #expect(vm.pendingLaunchTrackPick == nil)
    }
}
