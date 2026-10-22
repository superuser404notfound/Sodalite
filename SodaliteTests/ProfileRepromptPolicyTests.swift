import Testing
@testable import Sodalite

struct ProfileRepromptPolicyTests {
    /// Baseline where every gate passes; individual tests flip one input.
    private func decide(
        elapsed: Duration = .seconds(600),
        interval: AuthPreferences.ProfileRepromptInterval = .after5min,
        launchBehavior: AuthPreferences.LaunchBehavior = .showPicker,
        isAuthenticated: Bool = true,
        rememberedCount: Int = 2,
        isPlaybackRunning: Bool = false,
        tvUserChanged: Bool = false,
        wasBackgrounded: Bool = true
    ) -> Bool {
        ProfileRepromptPolicy.shouldReprompt(
            elapsed: elapsed, interval: interval, launchBehavior: launchBehavior,
            isAuthenticated: isAuthenticated, rememberedCount: rememberedCount,
            isPlaybackRunning: isPlaybackRunning, tvUserChanged: tvUserChanged,
            wasBackgrounded: wasBackgrounded)
    }

    @Test func baselinePrompts() { #expect(decide()) }
    @Test func offNeverPrompts() { #expect(!decide(interval: .off)) }
    @Test func immediatelyPromptsOnZeroElapsed() {
        #expect(decide(elapsed: .zero, interval: .immediately))
    }
    @Test func elapsedAtThresholdPrompts() {
        #expect(decide(elapsed: .seconds(300), interval: .after5min))
    }
    @Test func elapsedBelowThresholdDoesNot() {
        #expect(!decide(elapsed: .seconds(299), interval: .after5min))
    }
    @Test func useDefaultNeverPrompts() { #expect(!decide(launchBehavior: .useDefault)) }
    @Test func unauthenticatedNeverPrompts() { #expect(!decide(isAuthenticated: false)) }
    @Test func singleProfileNeverPrompts() { #expect(!decide(rememberedCount: 1)) }
    @Test func runningPlaybackBlocksPrompt() { #expect(!decide(isPlaybackRunning: true)) }
    @Test func tvUserChangeBlocksPrompt() { #expect(!decide(tvUserChanged: true)) }

    @Test func inactiveOnlyTripBelowFloorDoesNotPrompt() {
        #expect(!decide(elapsed: .seconds(5), interval: .immediately, wasBackgrounded: false))
        #expect(!decide(elapsed: .seconds(59), interval: .after30s, wasBackgrounded: false))
    }
    @Test func inactiveOnlyTripPastFloorPrompts() {
        #expect(decide(elapsed: .seconds(60), interval: .immediately, wasBackgrounded: false))
    }
    @Test func inactiveOnlyTripKeepsALongerThreshold() {
        #expect(!decide(elapsed: .seconds(299), interval: .after5min, wasBackgrounded: false))
        #expect(decide(elapsed: .seconds(300), interval: .after5min, wasBackgrounded: false))
    }

    @Test func shieldEligibilityIgnoresTime() {
        #expect(ProfileRepromptPolicy.canReprompt(
            interval: .after60min, launchBehavior: .showPicker, isAuthenticated: true, rememberedCount: 2))
        #expect(!ProfileRepromptPolicy.canReprompt(
            interval: .off, launchBehavior: .showPicker, isAuthenticated: true, rememberedCount: 2))
        #expect(!ProfileRepromptPolicy.canReprompt(
            interval: .immediately, launchBehavior: .useDefault, isAuthenticated: true, rememberedCount: 2))
        #expect(!ProfileRepromptPolicy.canReprompt(
            interval: .immediately, launchBehavior: .showPicker, isAuthenticated: true, rememberedCount: 1))
    }
}
