import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#63: a backward jump temporarily switches subtitles on until playback reaches the
/// position the jump started from. This type owns the policy so it stays testable without an engine.
@MainActor
struct SkipBackSubtitleWindowTests {

    private func stream(index: Int, codec: String? = "subrip", lang: String? = "en",
                        title: String? = nil, forced: Bool? = nil) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: forced,
                    isExternal: false, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    // MARK: - Origin of a press burst

    @Test("a second backward jump keeps the position the user actually left")
    func burstKeepsFurthestOrigin() {
        #expect(SkipBackSubtitleWindow.mergedOrigin(100, 90) == 100)
    }

    @Test("the first press of a burst takes the current playhead")
    func firstPressTakesPlayhead() {
        #expect(SkipBackSubtitleWindow.mergedOrigin(nil, 90) == 90)
    }

    // MARK: - Opening

    @Test("a backward jump with subtitles off opens the window")
    func opensOnBackwardJump() {
        #expect(SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 90, subtitlesActive: false, enabled: true))
    }

    @Test("a running subtitle is left alone")
    func doesNotOpenWhileSubtitlesRun() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 90, subtitlesActive: true, enabled: true))
    }

    @Test("the preference gates the window")
    func doesNotOpenWhenDisabled() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 90, subtitlesActive: false, enabled: false))
    }

    /// A pan or hold-to-seek never records an origin, so its commit must not open a window.
    @Test("a commit without a recorded origin opens nothing")
    func doesNotOpenWithoutOrigin() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: nil, targetTime: 90, subtitlesActive: false, enabled: true))
    }

    /// Skipping back at the very start clamps to 0 and can land where it started.
    @Test("a jump that does not actually move back opens nothing")
    func doesNotOpenOnZeroDistance() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 0.2, targetTime: 0, subtitlesActive: false, enabled: true))
    }

    // MARK: - The 30 second promise (Sodalite#65)

    @Test("the largest single press the app offers still opens a window")
    func opensOnLongestConfigurablePress() {
        #expect(SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 70, subtitlesActive: false, enabled: true))
    }

    @Test("a jump further back than 30 seconds opens nothing")
    func doesNotOpenBeyondThirtySeconds() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 69, subtitlesActive: false, enabled: true))
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 600, targetTime: 300, subtitlesActive: false, enabled: true))
    }

    /// Ten 10 s double taps are a rewind, not a catch-up: the window the first taps opened is closed
    /// again, and every further press keeps failing the same test instead of opening a fresh one.
    @Test("a burst that walks past 30 seconds leaves the promise")
    func burstLeavesThePromise() {
        #expect(SkipBackSubtitleWindow.withinPromise(origin: 100, landing: 70))
        #expect(!SkipBackSubtitleWindow.withinPromise(origin: 100, landing: 60))
        #expect(!SkipBackSubtitleWindow.withinPromise(origin: 100, landing: 0))
    }

    @Test("a press inside the burst measures against where the burst started")
    func burstKeepsItsOwnOrigin() {
        // Press two, half a second after press one: same burst, original origin kept.
        #expect(SkipBackSubtitleWindow.burstOrigin(
            previous: 100, playhead: 90, secondsSinceLastJump: 0.5) == 100)
        // A press after watching for a while is a new catch-up.
        #expect(SkipBackSubtitleWindow.burstOrigin(
            previous: 100, playhead: 90, secondsSinceLastJump: 10) == 90)
        // First press of a session.
        #expect(SkipBackSubtitleWindow.burstOrigin(
            previous: nil, playhead: 90, secondsSinceLastJump: nil) == 90)
    }

    /// Belt and braces behind the distance test: whatever origin a window ends up with, it never
    /// runs longer than 30 s past the point its jump landed on.
    @Test("a window never runs longer than 30 seconds after its landing")
    func windowIsBoundedByItsLanding() {
        let state = SkipBackSubtitleWindow.State(origin: 100, landing: 40, streamIndex: 3)
        #expect(SkipBackSubtitleWindow.end(of: state) == 70)
        #expect(SkipBackSubtitleWindow.shouldClose(state: state, playhead: 70))
        #expect(!SkipBackSubtitleWindow.shouldClose(state: state, playhead: 69))
    }

    @Test("a window inside the promise still ends where the jump started")
    func shortWindowEndsAtItsOrigin() {
        let state = SkipBackSubtitleWindow.State(origin: 100, landing: 90, streamIndex: 3)
        #expect(SkipBackSubtitleWindow.end(of: state) == 100)
    }

    // MARK: - Closing

    @Test("the window closes once playback reaches the origin")
    func closesAtOrigin() {
        let state = SkipBackSubtitleWindow.State(origin: 100, landing: 90, streamIndex: 3)
        #expect(SkipBackSubtitleWindow.shouldClose(state: state, playhead: 100))
        #expect(SkipBackSubtitleWindow.shouldClose(state: state, playhead: 101))
    }

    @Test("the window stays open short of the origin")
    func staysOpenBeforeOrigin() {
        let state = SkipBackSubtitleWindow.State(origin: 100, landing: 90, streamIndex: 3)
        #expect(!SkipBackSubtitleWindow.shouldClose(state: state, playhead: 99.5))
    }

    @Test("no window, nothing to close")
    func nothingToCloseWithoutState() {
        #expect(!SkipBackSubtitleWindow.shouldClose(state: nil, playhead: 100))
    }

    // MARK: - The last line finishes (Sodalite#178)

    private func cue(_ id: Int, _ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text("line \(id)"))
    }

    @Test("the line on screen at the window's end runs to its own end")
    func lineOnScreenFinishes() {
        let cues = [cue(1, 95, 97), cue(2, 99.5, 102.5)]
        #expect(SkipBackSubtitleWindow.lingerEnd(cues: cues, subtitleTime: 100, delay: 0) == 102.5)
    }

    @Test("nothing on screen closes at once")
    func noLineClosesNow() {
        let cues = [cue(1, 95, 97), cue(2, 101, 103)]
        #expect(SkipBackSubtitleWindow.lingerEnd(cues: cues, subtitleTime: 100, delay: 0) == nil)
        #expect(SkipBackSubtitleWindow.lingerEnd(cues: [], subtitleTime: 100, delay: 0) == nil)
    }

    @Test("the linger stops where the next line would start")
    func lingerNeverShowsANewLine() {
        let cues = [cue(1, 99, 103), cue(2, 101, 104)]
        #expect(SkipBackSubtitleWindow.lingerEnd(cues: cues, subtitleTime: 100, delay: 0) == 101)
    }

    @Test("a bitmap cue without a real end is bounded")
    func openEndedCueIsBounded() {
        let cues = [cue(1, 99, 400)]
        #expect(SkipBackSubtitleWindow.lingerEnd(cues: cues, subtitleTime: 100, delay: 0)
                == 100 + SkipBackSubtitleWindow.maximumLinger)
    }

    @Test("the subtitle delay shifts the lookup and the end the way the overlay does")
    func delayIsApplied() {
        // With a 2 s delay the overlay shows at clock 100 what is timed at 98.
        let cues = [cue(1, 97, 99), cue(2, 99.5, 101)]
        #expect(SkipBackSubtitleWindow.lingerEnd(cues: cues, subtitleTime: 100, delay: 2) == 101)
    }

    // MARK: - Track resolution

    @Test("the preferred subtitle language wins")
    func preferredLanguageWins() {
        let streams = [stream(index: 2, lang: "en"), stream(index: 3, lang: "de")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "de", audioLanguage: "eng") == 3)
    }

    /// The case applyPreferredSubtitle refuses to handle: audio is already in the user's language,
    /// which is exactly when someone asks "what did they say?".
    @Test("without a preferred language the audio language is used")
    func fallsBackToAudioLanguage() {
        let streams = [stream(index: 2, lang: "en"), stream(index: 3, lang: "de")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "eng") == 2)
    }

    @Test("a preferred language with no track falls through to the audio language")
    func preferredMissingFallsThrough() {
        let streams = [stream(index: 2, lang: "en")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "es", audioLanguage: "eng") == 2)
    }

    @Test("nothing matching means nothing is switched on")
    func noBlindFirstPick() {
        let streams = [stream(index: 2, lang: "th")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "eng") == nil)
    }

    @Test("a full track beats SDH and forced ones")
    func fullTrackWinsOverSDHAndForced() {
        let streams = [stream(index: 2, lang: "en", forced: true),
                       stream(index: 3, lang: "en", title: "English SDH"),
                       stream(index: 4, lang: "en")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "en") == 4)
    }

    @Test("text beats bitmap at equal descriptor rank")
    func textBeatsBitmap() {
        let streams = [stream(index: 2, codec: "hdmv_pgs_subtitle", lang: "en"),
                       stream(index: 3, codec: "subrip", lang: "en")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "en") == 3)
    }

    // MARK: - Track resolution on live

    /// The live case this exists for: a German channel carrying one subtitle stream that says `und`.
    @Test("on live an unlabelled track counts as the language being heard")
    func liveTakesTheUnlabelledTrack() {
        let streams = [stream(index: 2, codec: "dvb_teletext", lang: "und")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "de", audioLanguage: "deu",
            unlabelledCountsAsHeard: true) == 2)
    }

    @Test("a missing language tag is unlabelled too")
    func liveTakesTheUntaggedTrack() {
        let streams = [stream(index: 2, lang: nil)]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "deu",
            unlabelledCountsAsHeard: true) == 2)
    }

    /// A stated language is an answer, not a gap: the strict rule above already refused it.
    @Test("a track that states a foreign language is left alone on live too")
    func liveLeavesTaggedForeignTrackAlone() {
        let streams = [stream(index: 2, lang: "fr")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "de", audioLanguage: "deu",
            unlabelledCountsAsHeard: true) == nil)
    }

    @Test("a matching language still wins over an unlabelled track")
    func liveStillPrefersTheMatch() {
        let streams = [stream(index: 2, lang: "und"), stream(index: 3, lang: "de")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "de", audioLanguage: "deu",
            unlabelledCountsAsHeard: true) == 3)
    }

    @Test("two unlabelled tracks resolve by the same ranking as everywhere else")
    func liveRanksUnlabelledTracks() {
        let streams = [stream(index: 2, lang: "und", title: "SDH"),
                       stream(index: 3, lang: "und")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "deu",
            unlabelledCountsAsHeard: true) == 3)
    }

    /// Used directly by the live automatic pick, so it is worth a test of its own rather than only
    /// through `resolveTrack`.
    @Test("the unlabelled pick ignores tracks that state a language")
    func unlabelledPickSkipsTaggedTracks() {
        let streams = [stream(index: 2, lang: "fr"), stream(index: 3, lang: nil)]
        #expect(SkipBackSubtitleWindow.bestUnlabelledSubtitle(streams: streams) == 3)
    }

    @Test("nothing unlabelled means nothing to take")
    func unlabelledPickResolvesToNothing() {
        let streams = [stream(index: 2, lang: "fr"), stream(index: 3, lang: "en")]
        #expect(SkipBackSubtitleWindow.bestUnlabelledSubtitle(streams: streams) == nil)
    }

    /// VOD keeps the strict rule: a film with one unlabelled track switches nothing on.
    @Test("off live an unlabelled track is not taken")
    func vodLeavesUnlabelledTrackAlone() {
        let streams = [stream(index: 2, lang: "und")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "de", audioLanguage: "deu") == nil)
    }
}
