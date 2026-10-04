import Foundation
import AetherEngine

/// Sodalite#63, the tvOS "Automatic subtitles, Show on Skip Back" behaviour: a committed backward
/// jump switches subtitles on at the landing point and off again once playback has caught up with
/// the position the jump started from.
///
/// `PlayerViewModel` owns the wiring (origin capture in `seekJump`, opening in the scrub commits,
/// closing in the clock sink); this type owns the decisions so they stay unit-testable without an
/// engine, like `ForcedSubtitleFallback`.
enum SkipBackSubtitleWindow {
    struct State: Equatable {
        /// Playback position that ends the window, on the same clock as `PlayerViewModel.playbackTime`.
        var origin: Double
        /// Where the jump that opened (or last extended) the window landed, on the same clock. The
        /// window never runs longer than `maximumDistance` past it, whatever the origin says.
        var landing: Double
        /// The track this window switched on, so closing can never disable a different one.
        var streamIndex: Int
        /// Sodalite#178: set once the playhead reaches `end(of:)` while a line is on screen. The
        /// window then closes at this point on the subtitle clock, so that line is not cut short.
        var lingerUntil: Double? = nil
    }

    /// A jump shorter than this is treated as no movement: skipping back at the very start of a file
    /// clamps to zero and would otherwise open a window that closes on the next clock tick.
    private static let minimumDistance: Double = 0.5

    /// The setting this mirrors promises subtitles "when you skip back up to 30 seconds", and a
    /// window lasts until playback has caught up with where the jump started, so an ungated burst of
    /// presses turned subtitles on for minutes. 30 s is also the longest jump back the app offers
    /// (`skipIntervalChoices`, which both directions pick from), so one press always qualifies.
    ///
    /// Two places enforce it, deliberately: `shouldOpen` refuses a jump that is already longer, and
    /// `end(of:)` bounds the window itself. The second one is what holds, because the merge path
    /// keeps an already open window when more presses follow (those are the same catch-up) and any
    /// future path that opens or extends a window inherits the bound instead of having to remember it.
    static let maximumDistance: Double = 30

    /// Tolerates the rounding between a press interval and the position the seek actually lands on,
    /// so a 30 s press is not gated out by a few milliseconds.
    private static let distanceTolerance: Double = 0.5

    /// A press that follows a longer pause starts a new burst rather than extending the old one, so
    /// the promise is per burst: ten taps in a row are one 100 s rewind and show nothing, while a tap
    /// now and another one after watching a while are two ordinary catch-ups.
    static let burstGap: Double = 3

    /// Origin of a burst of backward jumps: the position furthest ahead wins, so three quick presses
    /// keep the place the user actually left instead of the last intermediate landing.
    static func mergedOrigin(_ existing: Double?, _ candidate: Double) -> Double {
        max(existing ?? candidate, candidate)
    }

    /// The origin a backward jump belongs to. It has to survive the commit that consumes the
    /// per-commit origin, because a burst that walks past the promised 30 s must keep failing the
    /// distance test for every further press; reading the playhead again each time would measure
    /// only the newest 10 s and let the window reopen.
    static func burstOrigin(previous: Double?, playhead: Double, secondsSinceLastJump: Double?) -> Double {
        guard let previous, let gap = secondsSinceLastJump, gap <= burstGap else { return playhead }
        return max(previous, playhead)
    }

    /// Whether a jump from `origin` landing at `landing` is still the catch-up the setting describes.
    static func withinPromise(origin: Double, landing: Double) -> Bool {
        origin - landing <= maximumDistance + distanceTolerance
    }

    static func shouldOpen(pendingOrigin: Double?, targetTime: Double,
                           subtitlesActive: Bool, enabled: Bool) -> Bool {
        guard enabled, !subtitlesActive, let pendingOrigin else { return false }
        return pendingOrigin - targetTime > minimumDistance
            && withinPromise(origin: pendingOrigin, landing: targetTime)
    }

    /// Where the window ends: the position the jump started from, or 30 s of playback after it
    /// landed, whichever comes first. A burst of presses commits as one jump on tvOS but as several
    /// on iOS, where each one merges into the open window and pushes the origin further out; the
    /// second half of this rule is what keeps both platforms inside the same promise.
    static func end(of state: State) -> Double {
        min(state.origin, state.landing + maximumDistance)
    }

    static func shouldClose(state: State?, playhead: Double) -> Bool {
        guard let state else { return false }
        return playhead >= end(of: state)
    }

    /// Bounds the linger, because a bitmap cue can carry an end time far past its real display
    /// (PGS often states none until the next display set).
    static let maximumLinger: Double = 8

    /// Sodalite#178: where the line on screen when the window reaches its end stops showing, on the
    /// subtitle clock. It runs to its own end time but never into the next line, so the window
    /// finishes what it showed and shows nothing new. nil when no line is on screen: close now.
    /// `delay` is the user's subtitle offset, applied the way the overlay applies it.
    static func lingerEnd(cues: [SubtitleCue], subtitleTime: Double, delay: Double) -> Double? {
        let lookup = subtitleTime - delay
        var lineEnd: Double?
        var nextStart = Double.infinity
        for cue in cues {
            if cue.startTime > lookup {
                nextStart = min(nextStart, cue.startTime)
            } else if cue.endTime > lookup {
                lineEnd = max(lineEnd ?? cue.endTime, cue.endTime)
            }
        }
        guard let lineEnd else { return nil }
        return min(lineEnd, nextStart, lookup + maximumLinger) + delay
    }

    /// Preferred subtitle language first, then the language being heard. A preferred language with no
    /// matching track falls through rather than giving up: the point of the window is reading back the
    /// dialogue that just played. Nothing matching resolves to nil, never to an arbitrary first track.
    ///
    /// `unlabelledCountsAsHeard` is the live exception, see `bestUnlabelledSubtitle`.
    static func resolveTrack(streams: [MediaStream], preferredSubtitleLanguage: String?,
                             audioLanguage: String?, unlabelledCountsAsHeard: Bool = false) -> Int? {
        if let preferred = preferredSubtitleLanguage,
           let match = bestSubtitle(streams: streams, language: preferred) {
            return match
        }
        if let audioLanguage, let match = bestSubtitle(streams: streams, language: audioLanguage) {
            return match
        }
        guard unlabelledCountsAsHeard else { return nil }
        return bestUnlabelledSubtitle(streams: streams)
    }

    /// Live TV: broadcasters tag their subtitle stream `und`, or nothing at all, as a matter of
    /// routine, so a language match finds nothing on exactly the channels this is meant for. A track
    /// that states no language is read as the language of the broadcast, which is the language being
    /// heard. Tracks that do state one are left out of this: a stated `eng` on a German channel is an
    /// answer, not a gap, and the strict rule above already had its say on it. Ranking is the same as
    /// everywhere else, so two unlabelled tracks resolve to the more useful one rather than the first.
    ///
    /// Shared with `SystemCaptionWindow` and with the live automatic pick in `applyPreferredSubtitle`,
    /// which reaches the same dead end from the other side: a configured subtitle language that no
    /// track on the channel states.
    static func bestUnlabelledSubtitle(streams: [MediaStream]) -> Int? {
        streams
            .filter { $0.type == .subtitle && PlayerViewModel.isLanguageUnknown($0.language) }
            .min(by: { PlayerViewModel.subtitleAutoPickRank($0) < PlayerViewModel.subtitleAutoPickRank($1) })?
            .index
    }

    /// Shared with `SystemCaptionWindow`, which resolves the language the system picked the same way.
    static func bestSubtitle(streams: [MediaStream], language: String) -> Int? {
        streams
            .filter { $0.type == .subtitle && PlayerViewModel.languagesMatch($0.language, language) }
            .min(by: { PlayerViewModel.subtitleAutoPickRank($0) < PlayerViewModel.subtitleAutoPickRank($1) })?
            .index
    }
}
