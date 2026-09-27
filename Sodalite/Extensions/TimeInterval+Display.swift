import Foundation

extension TimeInterval {
    /// The one spelling of a duration in the app, a runtime, a time remaining and a countdown alike:
    /// "52m" / "1h 48m" / "2h" (en), "1h 48min" (de), "1sa 48d" (tr) (Sodalite#165). CLDR's narrow
    /// units rather than suffixes of our own: those put German at 69.9pt against 51.1 and Polish at
    /// 74.5 against 51.1 on the resume label (Sodalite#99), and five languages never had theirs
    /// translated at all.
    ///
    /// Always rounded UP, so a time left never promises less than there is and "0m" cannot appear
    /// for anything longer than zero. A runtime takes the same rounding, or a film of 1h 47m 10s
    /// would list 1h 47m and show 1h 48m left five seconds in.
    var durationDisplay: String {
        Duration.seconds(Swift.max(0, self))
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow,
                              fractionalPart: .hide(rounded: .up)))
    }
}

extension Int64 {
    /// Jellyfin ticks (100ns units) as `durationDisplay`.
    var ticksToDurationDisplay: String {
        ticksToSeconds.durationDisplay
    }

    /// Convert Jellyfin ticks to TimeInterval (seconds)
    var ticksToSeconds: TimeInterval {
        TimeInterval(self) / 10_000_000
    }
}
