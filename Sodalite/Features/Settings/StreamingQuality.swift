import Foundation

/// What the quality picker needs to know about the file on screen: Jellyfin's facts for the library file.
struct TranscodeSourceFacts: Equatable, Sendable {
    let bitrate: Int?
    let width: Int?
    let frameRate: Double?
}

/// Whether a server encodes transcodes in HEVC, an admin setting a client cannot read. A probe or a
/// delivered transcode answers it, so it is kept per server (Sodalite#87). Unknown reads as H.264,
/// Jellyfin's default.
struct TranscodeCodecMemory {
    let defaults: UserDefaults

    private func key(_ server: String) -> String { "playback.transcodeVideoCodec.\(server)" }

    /// "hevc" or "h264", nil until a probe or a transcode has said.
    func knownCodec(server: String?) -> String? {
        guard let server else { return nil }
        return defaults.string(forKey: key(server))
    }

    func encodesHEVC(server: String?) -> Bool {
        knownCodec(server: server) == "hevc"
    }

    func record(server: String?, deliveredCodec: String) {
        guard let server else { return }
        let codec = deliveredCodec.lowercased()
        guard codec == "hevc" || codec == "h264" else { return }
        defaults.set(codec, forKey: key(server))
    }
}

/// Asks a server once which codec it transcodes in, before any transcode has run (Sodalite#87). The
/// master playlist of a transcode names it in CODECS, and Jellyfin builds that playlist from the
/// computed streaming state without starting ffmpeg, which only starts on a segment request.
enum TranscodeCodecProbe {
    /// Low enough that practically every source is transcoded, so the answer carries a transcode URL.
    static let probeCap = 1_000_000

    static func videoCodec(fromMaster master: String) -> String? {
        guard let start = master.range(of: "CODECS=\""),
              let end = master[start.upperBound...].firstIndex(of: "\"") else { return nil }
        for token in master[start.upperBound..<end].split(separator: ",") {
            let codec = token.trimmingCharacters(in: .whitespaces).lowercased()
            if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return "hevc" }
            if codec.hasPrefix("avc1") || codec.hasPrefix("avc3") { return "h264" }
        }
        return nil
    }

    /// Probes and records, unless the server is already known. Returns what it found, nil when it
    /// could not tell (no transcode URL for this item, the fetch failed).
    @MainActor
    @discardableResult
    static func run(itemID: String, userID: String, server: String?, mediaSourceID: String? = nil,
                    service: JellyfinPlaybackServiceProtocol, memory: TranscodeCodecMemory,
                    resolve: (String) -> URL?, fetch: (URL) async -> String?) async -> String? {
        guard let server, memory.knownCodec(server: server) == nil else { return nil }
        // Pinned to the source being played so the server picks no subtitle to burn in (see
        // `vodPlaybackInfoBody`).
        guard let info = try? await service.getPlaybackInfo(
                itemID: itemID, userID: userID,
                profile: DirectPlayProfile.current(maxStreamingBitrate: probeCap),
                mediaSourceID: mediaSourceID, audioStreamIndex: nil),
              let path = info.mediaSources.first?.transcodingUrl,
              let url = resolve(path),
              let master = await fetch(url),
              let codec = videoCodec(fromMaster: master) else { return nil }
        memory.record(server: server, deliveredCodec: codec)
        LogTap.shared.note("[Quality] \(server) transcodes in \(codec) (probed)")
        return codec
    }
}

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

    /// The picker row's caption: what this rung produces for the file on screen. The file's own
    /// resolution where it fits under the cap, the width Jellyfin will pick where it does not
    /// (`TranscodeResolutionEstimate`). A rung is a bitrate cap and never forces a resolution, so a fixed
    /// "(1080p)" in the name promised something it did not hold for a 4K file under the cap.
    func pickerHint(source: TranscodeSourceFacts, serverEncodesHEVC: Bool) -> String? {
        let fileLabel = source.width.map(TranscodeResolutionEstimate.label(width:))
        guard let cap = maxStreamingBitrate else { return fileLabel }
        guard bites(sourceBitrate: source.bitrate) else {
            let original = String(localized: "player.quality.short.original", defaultValue: "Original")
            return fileLabel.map { "\($0) · \(original)" } ?? original
        }
        let transcode = String(localized: "player.quality.reencodes", defaultValue: "Transcode")
        let width = TranscodeResolutionEstimate.width(
            cap: cap, outputCodec: serverEncodesHEVC ? "hevc" : "h264",
            frameRate: source.frameRate, sourceWidth: source.width)
        return width.map { "\(TranscodeResolutionEstimate.label(width: $0)) · \(transcode)" } ?? transcode
    }

    /// The rung a new session starts on. An unknown path counts as Wi-Fi, so a missing first
    /// NWPathMonitor callback never silently downgrades a session.
    static func resolve(wifi: StreamingQuality, cellular: StreamingQuality,
                        reading: NetworkPathSnapshot.Reading?, platformHasCellular: Bool) -> StreamingQuality {
        guard platformHasCellular, reading?.isMetered == true else { return wifi }
        return cellular
    }
}
