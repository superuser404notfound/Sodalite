import Foundation

/// Formats a seconds value as `m:ss` (or `h:mm:ss`) for the music player and
/// now-playing card. Shared so the player bar and the mini card stay in sync.
enum MusicTimeFormatter {
    static func string(_ seconds: Double) -> String {
        seconds.clockDisplay()
    }
}
