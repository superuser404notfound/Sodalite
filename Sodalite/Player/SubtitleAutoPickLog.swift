import Foundation

/// Sodalite#255: one diagnostic line per automatic subtitle decision, so a log answers why subtitles
/// came up (or stayed off) at the start of a title. Before this the log said nothing about a
/// remembered pick or the language rules, and the forced fallback named only a stream index, so
/// "English subtitles on English audio" could not be told apart from a full track tagged forced.
///
/// `PlayerViewModel` decides; this type only words the decision, so the wording stays testable.
enum SubtitleAutoPickLog {
    static let prefix = "[Subtitles] auto pick:"

    enum RememberedSource: Equatable {
        /// Track memory, per movie or per series ("Remember track selection").
        case trackMemory
        /// The detail page's track pick for this launch (Sodalite#250).
        case detailPage
    }

    enum RuleOutcome: Equatable {
        /// Preferred Subtitle Language is set; `picked` is nil when the title has no such track.
        case preferredLanguage(String, picked: MediaStream?)
        /// The audio is not the preferred audio language; `picked` is nil without a matching track.
        case foreignAudio(audio: String, preferred: String, picked: MediaStream?)
        /// The audio is the preferred language or carries no language tag, so the rule stays out.
        case audioNotForeign(audio: String?, preferred: String)
        case foreignRuleOff
        /// Preferred audio on Auto and a device locale without a language code.
        case noPreferredAudio
    }

    /// The track as the rules see it. The flags matter most here: a full track the file tags as
    /// forced looks like any other track in the menu.
    static func describe(_ stream: MediaStream) -> String {
        var parts = ["#\(stream.index)", stream.language ?? "und", stream.codec ?? "?"]
        if let title = stream.title, !title.isEmpty { parts.append("\"\(title)\"") }
        let flags = [
            stream.isForced == true ? "forced" : nil,
            stream.isHearingImpaired == true ? "sdh" : nil,
            stream.isDefault == true ? "default" : nil,
            stream.isExternal == true ? "external" : nil,
        ].compactMap { $0 }
        if !flags.isEmpty { parts.append("[" + flags.joined(separator: ",") + "]") }
        return parts.joined(separator: " ")
    }

    /// `streamIndex` nil means the remembered choice is Off.
    static func rememberedLine(streamIndex: Int?, streams: [MediaStream], source: RememberedSource) -> String {
        let reason = source == .trackMemory ? "remembered for this title" : "picked on the detail page"
        guard let streamIndex else { return "\(prefix) off, \(reason)" }
        return "\(prefix) \(label(streamIndex, in: streams)), \(reason)"
    }

    static func ruleLine(_ outcome: RuleOutcome) -> String {
        switch outcome {
        case .preferredLanguage(let language, let picked?):
            return "\(prefix) \(describe(picked)), Preferred Subtitle Language \(language)"
        case .preferredLanguage(let language, nil):
            return "\(prefix) nothing, no \(language) track for Preferred Subtitle Language"
        case .foreignAudio(let audio, let preferred, let picked?):
            return "\(prefix) \(describe(picked)), audio \(audio) is foreign to \(preferred)"
        case .foreignAudio(let audio, let preferred, nil):
            return "\(prefix) nothing, audio \(audio) is foreign to \(preferred) but no \(preferred) track"
        case .audioNotForeign(let audio?, let preferred):
            return "\(prefix) nothing, audio \(audio) is not foreign to \(preferred)"
        case .audioNotForeign(nil, _):
            return "\(prefix) nothing, audio language unknown"
        case .foreignRuleOff:
            return "\(prefix) nothing, Subtitles for foreign audio is off"
        case .noPreferredAudio:
            return "\(prefix) nothing, no preferred audio language"
        }
    }

    static func forcedFallbackLine(_ mode: ForcedSubtitleFallback.Mode, streams: [MediaStream],
                                   audioLanguage: String?) -> String {
        let audio = "audio \(audioLanguage ?? "unknown")"
        switch mode {
        case .none:
            return "[Subtitles] forced fallback: none, \(audio)"
        case .forcedTrack(let index):
            return "[Subtitles] forced fallback: whole track \(label(index, in: streams)), \(audio)"
        case .cueFilter(let index):
            return "[Subtitles] forced fallback: forced cues of \(label(index, in: streams)), \(audio)"
        }
    }

    private static func label(_ index: Int, in streams: [MediaStream]) -> String {
        streams.first { $0.index == index }.map(describe) ?? "#\(index)"
    }
}
