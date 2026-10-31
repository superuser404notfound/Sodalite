import Foundation
import Testing
import AetherEngine
@testable import Sodalite

/// Sodalite#219. The newest detail page owns the theme song, a page that hands over to one with the
/// same song keeps it running, and anything else making sound silences it until a page opens again.
@Suite("Theme song player")
@MainActor
struct ThemeSongPlayerTests {
    final class RecordingOutput: ThemeSongOutput {
        private(set) var currentSongID: String?
        private(set) var plays: [String] = []
        private(set) var stops = 0

        func play(_ target: ThemeSongTarget) {
            currentSongID = target.songID
            plays.append(target.songID)
        }

        func stop() {
            if currentSongID != nil { stops += 1 }
            currentSongID = nil
        }
    }

    final class Switches {
        var enabled = true
        var blocked = false
        var lookups: [String] = []
    }

    private func song(_ id: String) -> ThemeSongTarget {
        ThemeSongTarget(songID: id, url: URL(string: "http://server/Audio/\(id)/universal")!)
    }

    private func make() -> (ThemeSongPlayer, RecordingOutput, Switches) {
        let output = RecordingOutput()
        let switches = Switches()
        let player = ThemeSongPlayer(
            output: output,
            isEnabled: { switches.enabled },
            isBlocked: { switches.blocked },
            releaseGrace: .milliseconds(20)
        )
        return (player, output, switches)
    }

    private func resolver(_ songID: String?, key: String, _ switches: Switches) -> @MainActor () async -> ThemeSongTarget? {
        { [song] in
            switches.lookups.append(key)
            return songID.map(song)
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test("a page plays its song")
    func playsOnClaim() async {
        let (player, output, switches) = make()
        _ = player.claim(key: "s:series", resolve: resolver("theme-a", key: "s:series", switches))
        await settle()
        #expect(output.plays == ["theme-a"])
    }

    @Test("off by default means nothing is fetched or played")
    func disabledPlaysNothing() async {
        let (player, output, switches) = make()
        switches.enabled = false
        _ = player.claim(key: "s:series", resolve: resolver("theme-a", key: "s:series", switches))
        await settle()
        #expect(output.plays.isEmpty)
        #expect(switches.lookups.isEmpty)
    }

    @Test("a season of the same series keeps the song running")
    func sameSongContinuesAcrossPush() async {
        let (player, output, switches) = make()
        let series = player.claim(key: "s:series", resolve: resolver("theme-a", key: "s:series", switches))
        await settle()
        _ = player.claim(key: "s:season", resolve: resolver("theme-a", key: "s:season", switches))
        player.release(series)
        await settle()
        #expect(output.plays == ["theme-a"])
        #expect(output.stops == 0)
    }

    @Test("walking back plays the earlier page's song from cache")
    func walkingBackUsesCache() async {
        let (player, output, switches) = make()
        _ = player.claim(key: "s:movie-1", resolve: resolver("theme-1", key: "s:movie-1", switches))
        await settle()
        let second = player.claim(key: "s:movie-2", resolve: resolver("theme-2", key: "s:movie-2", switches))
        await settle()
        player.release(second)
        await settle()
        #expect(output.plays == ["theme-1", "theme-2", "theme-1"])
        #expect(switches.lookups == ["s:movie-1", "s:movie-2"])
    }

    @Test("a page without a song stops the one before it")
    func pageWithoutSongStops() async {
        let (player, output, switches) = make()
        _ = player.claim(key: "s:series", resolve: resolver("theme-a", key: "s:series", switches))
        await settle()
        _ = player.claim(key: "s:other", resolve: resolver(nil, key: "s:other", switches))
        await settle()
        #expect(output.currentSongID == nil)
        #expect(output.stops == 1)
    }

    @Test("closing the last page stops after the grace")
    func lastReleaseStops() async {
        let (player, output, switches) = make()
        let page = player.claim(key: "s:series", resolve: resolver("theme-a", key: "s:series", switches))
        await settle()
        player.release(page)
        #expect(output.currentSongID == "theme-a")
        await settle()
        #expect(output.currentSongID == nil)
    }

    @Test("playback silences the song and it stays silent after the player closes")
    func silenceSpendsOpenPages() async {
        let (player, output, switches) = make()
        _ = player.claim(key: "s:movie", resolve: resolver("theme-a", key: "s:movie", switches))
        await settle()
        switches.blocked = true
        player.silence()
        #expect(output.currentSongID == nil)
        switches.blocked = false
        player.evaluate()
        await settle()
        #expect(output.plays == ["theme-a"])
    }

    @Test("a page opened while something plays stays silent")
    func blockedClaimPlaysNothing() async {
        let (player, output, switches) = make()
        switches.blocked = true
        _ = player.claim(key: "s:movie", resolve: resolver("theme-a", key: "s:movie", switches))
        await settle()
        #expect(output.plays.isEmpty)
    }

    @Test("coming back to the front plays the page on top again")
    func resumeAfterBackground() async {
        let (player, output, switches) = make()
        _ = player.claim(key: "s:movie", resolve: resolver("theme-a", key: "s:movie", switches))
        await settle()
        player.silence()
        player.resume()
        await settle()
        #expect(output.plays == ["theme-a", "theme-a"])
    }

    @Test("switching the setting off stops the song")
    func disablingStops() async {
        let (player, output, switches) = make()
        _ = player.claim(key: "s:movie", resolve: resolver("theme-a", key: "s:movie", switches))
        await settle()
        switches.enabled = false
        player.evaluate()
        #expect(output.currentSongID == nil)
    }

    @Test("only a session-less engine leaves room for a song")
    func quietStates() {
        #expect(ThemeSongPlayer.isQuiet(.idle))
        #expect(ThemeSongPlayer.isQuiet(.ended))
        #expect(ThemeSongPlayer.isQuiet(.error("x")))
        #expect(!ThemeSongPlayer.isQuiet(.playing))
        #expect(!ThemeSongPlayer.isQuiet(.paused))
        #expect(!ThemeSongPlayer.isQuiet(.loading))
        #expect(!ThemeSongPlayer.isQuiet(.seeking))
    }
}
