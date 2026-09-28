import Foundation

/// Sodalite#87: a ceiling on what leaves the server, not a mode. The cap travels as
/// `MaxStreamingBitrate`, so a file already under it still direct-plays and only a file above it is
/// re-encoded. A fixed list of rungs rather than a slider, because that is what a server can deliver
/// and what a viewer can reason about.
enum StreamingQuality: String, CaseIterable, Sendable, Identifiable {
    case original, mbps40, mbps20, mbps10, mbps4, mbps2

    var id: String { rawValue }
    var titleKey: String { "settings.playback.quality.\(rawValue)" }

    var maxStreamingBitrate: Int? {
        switch self {
        case .original: return nil
        case .mbps40:   return 40_000_000
        case .mbps20:   return 20_000_000
        case .mbps10:   return 10_000_000
        case .mbps4:    return 4_000_000
        case .mbps2:    return 2_000_000
        }
    }

    /// Whether this rung makes the server re-encode a source of `sourceBitrate`. An unknown bitrate
    /// counts as biting: the label then warns about a cost that may not come, never the reverse.
    func bites(sourceBitrate: Int?) -> Bool {
        guard let cap = maxStreamingBitrate else { return false }
        guard let sourceBitrate else { return true }
        return sourceBitrate > cap
    }

    /// Chip text on the transport bar: "Original" or "10 Mbit/s".
    var shortLabel: String {
        guard let cap = maxStreamingBitrate else {
            return String(localized: "player.quality.short.original", defaultValue: "Original")
        }
        return String(format: String(localized: "player.quality.short.mbps", defaultValue: "%lld Mbit/s"),
                      Int64(cap / 1_000_000))
    }

    /// The picker row's trailing caption, present only where the rung actually costs a re-encode.
    func pickerHint(sourceBitrate: Int?) -> String? {
        bites(sourceBitrate: sourceBitrate)
            ? String(localized: "player.quality.reencodes", defaultValue: "Transcode")
            : nil
    }

    /// The rung a new session starts on. An unknown path counts as Wi-Fi, so a missing first
    /// NWPathMonitor callback never silently downgrades a session.
    static func resolve(wifi: StreamingQuality, cellular: StreamingQuality,
                        reading: NetworkPathSnapshot.Reading?, platformHasCellular: Bool) -> StreamingQuality {
        guard platformHasCellular, reading?.isMetered == true else { return wifi }
        return cellular
    }
}
