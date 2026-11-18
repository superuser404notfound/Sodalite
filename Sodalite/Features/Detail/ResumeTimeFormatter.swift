import Foundation

/// Formats Jellyfin playbackPositionTicks (100-ns ticks) into a compact resume label: "12:34" sub-hour, "1:02:45" past an hour. Language-neutral, so it's reused across all 26 locales without the catalog.
enum ResumeTimeFormatter {
    /// Takes Int64 (mirrors playbackPositionTicks) so call sites don't wrap in Int(...); Swift won't widen Int→Int64 implicitly.
    static func format(ticks: Int64) -> String? {
        guard ticks > 0 else { return nil }
        return ticks.ticksToSeconds.clockDisplay()
    }
}
