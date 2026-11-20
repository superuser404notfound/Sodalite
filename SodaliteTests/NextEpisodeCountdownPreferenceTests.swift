import Testing
import Foundation
@testable import Sodalite

/// Sodalite#133. The countdown grew from a switch into a length plus an anchor: how long the ring runs,
/// and whether it is placed on the credits (cutting them short) or on the end of the source.
struct NextEpisodeCountdownPreferenceTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "NextEpisodeCountdownPreferenceTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test func lengthDefaultsToFifteenSeconds() {
        #expect(PlaybackPreferences(store: defaults(#function)).nextEpisodeCountdownSeconds == 15)
    }

    /// The credits anchor is what shipped, so an untouched install keeps behaving as it did.
    @Test func anchorDefaultsToTheCredits() {
        #expect(PlaybackPreferences(store: defaults(#function)).nextEpisodeCountdownAnchor == .outro)
    }

    /// The card is what shipped, so an untouched install keeps it.
    @Test func cardDefaultsToOn() {
        #expect(PlaybackPreferences(store: defaults(#function)).showNextEpisodeCard)
    }

    @Test func cardSwitchPersistsAcrossInstances() {
        let store = defaults(#function)
        PlaybackPreferences(store: store).showNextEpisodeCard = false
        #expect(PlaybackPreferences(store: store).showNextEpisodeCard == false)
    }

    @Test func anchorPersistsAcrossInstances() {
        let store = defaults(#function)
        let a = PlaybackPreferences(store: store)
        a.nextEpisodeCountdownAnchor = .end
        #expect(PlaybackPreferences(store: store).nextEpisodeCountdownAnchor == .end)
    }

    /// A raw value that is no longer known (downgrade, corrupt defaults) must fall back, not crash.
    @Test func anchorFallsBackOnAnUnknownRawValue() {
        let store = defaults(#function)
        store.set("sometime", forKey: "playback.nextEpisodeCountdownAnchor")
        #expect(PlaybackPreferences(store: store).nextEpisodeCountdownAnchor == .outro)
    }

    /// Off is a value of the length row, so the row can carry the whole setting. It is deliberately not
    /// labelled "0 s": a zero-second countdown on the credits anchor would be an instant jump, which is
    /// what `autoSkipOutro` already offers.
    @Test func lengthChoicesStartAtOffAndEndAtThirty() {
        #expect(PlaybackPreferences.nextEpisodeCountdownChoices == [0, 5, 10, 15, 20, 30])
    }

    /// The stored on/off flag stays the truth for "off" (older builds sync it, and `endOfPlaybackOutcome`
    /// reads it), so picking Off in the row must clear it and picking a length must set it.
    @Test func theLengthRowWritesThroughToTheOnOffFlag() {
        let store = defaults(#function)
        let prefs = PlaybackPreferences(store: store)
        prefs.nextEpisodeCountdownLength = 0
        #expect(prefs.autoplayCountdown == false)
        #expect(prefs.nextEpisodeCountdownLength == 0)

        prefs.nextEpisodeCountdownLength = 30
        #expect(prefs.autoplayCountdown == true)
        #expect(prefs.nextEpisodeCountdownSeconds == 30)
    }

    /// Switching off must not forget the chosen length: switching back on restores it rather than
    /// dropping the user on the default.
    @Test func switchingOffKeepsTheChosenLength() {
        let store = defaults(#function)
        let prefs = PlaybackPreferences(store: store)
        prefs.nextEpisodeCountdownLength = 5
        prefs.nextEpisodeCountdownLength = 0
        #expect(prefs.nextEpisodeCountdownSeconds == 5)
        #expect(prefs.nextEpisodeCountdownLength == 0)
    }

    /// What the player asks for: off means no countdown at all, whatever the stored length says.
    @Test func theEffectiveLengthIsZeroWhileTheCountdownIsOff() {
        let store = defaults(#function)
        let prefs = PlaybackPreferences(store: store)
        prefs.autoplayCountdown = false
        #expect(prefs.nextEpisodeCountdownLength == 0)
        prefs.autoplayCountdown = true
        #expect(prefs.nextEpisodeCountdownLength == 15)
    }
}
