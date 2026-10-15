import Foundation
import AetherEngine

/// Formats TrackInfo into localized player-UI strings (language names via
/// `Locale.current.localizedString(forLanguageCode:)`).
/// Audio: "Deutsch · Dolby Digital 5.1", subtitle: "Englisch".
enum TrackDisplayFormatter {

    static func audioDisplayName(for track: TrackInfo) -> String {
        var parts: [String] = []

        if let lang = languageName(for: track) {
            parts.append(lang)
        }

        // Atmos overrides the bed-channel description (5.1 + JOC = "Dolby
        // Atmos", not "Dolby Digital+ 5.1"), matching other Atmos UIs.
        if track.isAtmos {
            parts.append("Dolby Atmos")
        } else if isTrueHDAtmos(track) {
            parts.append("Dolby TrueHD Atmos")
        } else if isDTSX(track) {
            parts.append("DTS:X")
        } else {
            let quality = audioQuality(for: track)
            if !quality.isEmpty {
                parts.append(quality)
            }
        }

        if parts.isEmpty {
            return String(localized: "player.track.unknown", defaultValue: "Unknown")
        }
        return parts.joined(separator: " · ")
    }

    static func subtitleDisplayName(for track: TrackInfo) -> String {
        if let title = titleIfUseful(track), let lang = languageName(for: track) {
            return "\(lang) (\(title))"
        }
        return languageName(for: track)
            ?? String(localized: "player.track.unknown", defaultValue: "Unknown")
    }

    /// Subtitle MediaStream name: Jellyfin displayTitle if useful, else built
    /// from language + flags.
    static func subtitleStreamDisplayName(for stream: MediaStream) -> String {
        let lang = streamLanguageName(for: stream)

        var descriptors: [String] = []
        if stream.isForced == true { descriptors.append("Forced") }
        if let title = stream.title, !title.isEmpty {
            let lower = title.lowercased()
            let useful = ["sdh", "commentary", "cc", "signs", "songs", "full", "hearing", "forced", "musik", "music"]
            if useful.contains(where: { lower.contains($0) }) {
                if let lang { return "\(lang) (\(title))" }
                return title
            }
        }
        if !descriptors.isEmpty, let lang {
            return "\(lang) (\(descriptors.joined(separator: ", ")))"
        }
        return lang ?? stream.displayTitle
            ?? String(localized: "player.track.unknown", defaultValue: "Unknown")
    }

    static func subtitleShortName(for stream: MediaStream) -> String {
        streamLanguageName(for: stream) ?? stream.displayTitle ?? "Sub"
    }

    /// Transport-bar label: the language, which is what a viewer picks by. Live channels routinely
    /// tag no language at all, and the container's own name for such a track is "Track 0 (aac)", so
    /// the fallback is the format description the menu row also carries. `track.name` is the last
    /// resort, for a track that has neither.
    static func shortName(for track: TrackInfo) -> String {
        if let lang = languageName(for: track) { return lang }
        if track.isAtmos { return "Dolby Atmos" }
        if isTrueHDAtmos(track) { return "Dolby TrueHD Atmos" }
        if isDTSX(track) { return "DTS:X" }
        let quality = audioQuality(for: track)
        return quality.isEmpty ? track.name : quality
    }

    /// AetherEngine#731: `TrackInfo.isAtmos` answers for E-AC-3 JOC only. A TrueHD Atmos track is told by
    /// the profile FFmpeg reads off its major sync, the same test `MediaBadges` applies to the server's
    /// stream profile, and with the heights setting on it is the track that keeps them.
    static func isTrueHDAtmos(_ track: TrackInfo) -> Bool {
        track.codec.lowercased() == "truehd"
            && (track.profile?.localizedCaseInsensitiveContains("Dolby Atmos") ?? false)
    }

    /// AetherEngine#744: DTS:X keeps its heights the same way. The engine's flag covers the profile
    /// FFmpeg reads and a track LibDTSX confirmed while it played, which FFmpeg labels plain DTS-HD MA.
    static func isDTSX(_ track: TrackInfo) -> Bool {
        track.isDTSX
    }

    private static func isDTS(_ codec: String) -> Bool {
        ["dca", "dts"].contains(codec.lowercased())
    }

    // MARK: - Private

    private static func streamLanguageName(for stream: MediaStream) -> String? {
        languageName(forCode: stream.language)
    }

    private static func languageName(for track: TrackInfo) -> String? {
        languageName(forCode: track.language)
    }

    /// The viewer's name for a language tag, or nil when the tag carries no language. "und" is the
    /// ISO code for undetermined, i.e. the container stating it does not know, and Locale turns that
    /// into "Unknown language", which reads like a language and is worse on a chip than the format.
    /// Live channels tag their streams that way routinely.
    private static func languageName(forCode code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let normalized = code.lowercased()
        guard normalized != "und", normalized != "unknown" else { return nil }
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code.uppercased()
    }

    private static func audioQuality(for track: TrackInfo) -> String {
        let codecDisplay = isDTS(track.codec) ? dtsDisplayName(profile: track.profile) : codecDisplayName(track.codec)
        let channelDisplay = channelLayout(track.channels)

        if !codecDisplay.isEmpty && !channelDisplay.isEmpty {
            return "\(codecDisplay) \(channelDisplay)"
        }
        return codecDisplay.isEmpty ? channelDisplay : codecDisplay
    }

    private static func codecDisplayName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "aac": return "AAC"
        case "ac3": return "Dolby Digital"
        case "eac3": return "Dolby Digital+"
        case "truehd": return "Dolby TrueHD"
        case "dts": return "DTS"
        case "dts-hd", "dtshd": return "DTS-HD"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3", "mp3float": return "MP3"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le": return "PCM"
        default: return codec.uppercased()
        }
    }

    /// The DTS family shares one codec, so the profile is what says which member a track is.
    private static func dtsDisplayName(profile: String?) -> String {
        guard let profile else { return "DTS" }
        for name in ["DTS-HD MA", "DTS-HD HRA"] where profile.hasPrefix(name) { return name }
        return "DTS"
    }

    private static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let n where n > 0: return "\(n)ch"
        default: return ""
        }
    }

    /// Track title only if it carries metadata beyond the language name
    /// (e.g. "Forced", "SDH", "Commentary").
    private static func titleIfUseful(_ track: TrackInfo) -> String? {
        guard let title = track.name.nilIfEmpty else { return nil }
        if let lang = track.language {
            let langName = Locale.current.localizedString(forLanguageCode: lang) ?? ""
            if title.caseInsensitiveCompare(lang) == .orderedSame
                || title.caseInsensitiveCompare(langName) == .orderedSame {
                return nil
            }
        }
        let useful = ["forced", "sdh", "commentary", "cc", "signs", "songs", "full", "hearing"]
        let lower = title.lowercased()
        if useful.contains(where: { lower.contains($0) }) {
            return title
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
