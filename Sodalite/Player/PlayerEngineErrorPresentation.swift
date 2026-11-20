import AetherEngine
import Foundation

/// Turns the engine's typed failure (`PlaybackErrorInfo`, AetherEngine#376) into the error screen's
/// icon + title + body trio.
///
/// Before this existed the host published `PlaybackState.error`'s text verbatim, which is the engine's own
/// English sentence about half the time ("Failed to load: HTTP 403 ..."). In a 26-language app that is an
/// untranslated string, and worse, it describes the plumbing rather than what the viewer can do: a refused
/// stream, a missing file and a metered origin all read the same. `kind` is the key that survives a locale
/// and a release (AetherEngine#378), so the host classifies on it and writes its own sentence.
///
/// Classification and copy are separate on purpose: `face(for:)` is testable without a locale, and only
/// `trio(for:engineMessage:)` reaches into the string catalog.
enum PlayerEngineErrorPresentation {

    /// Which of the host's error faces a typed failure maps to. Deliberately smaller than the engine's kind
    /// set: a face exists only where the host has a sentence that beats the engine's own.
    enum Face: Equatable {
        /// The origin answered the source request with a refusal (401 / 403).
        case streamRefused(status: Int)
        /// The origin says the file is not there any more (404 / 410).
        case streamNotFound
        /// The origin answered with a status instead of media, and it is the server's own fault (5xx).
        case streamServerError(status: Int)
        /// The origin is metering us (429 / 503 / 509). The source is not gone and the same request is
        /// expected to work later, so the copy asks for patience rather than reporting a failure.
        case rateLimited
        /// Dolby Vision with no base layer this device can decode.
        case dolbyVisionUnsupported
        /// A live probe that burned its reconnect budget without opening.
        case liveChannelUnavailable
        /// The audio track cannot be carried: either the bridge produced nothing for it (AE#396) or a
        /// switch onto it failed and took its session with it. The only face whose advice is not "try
        /// again", which is the whole reason it exists rather than folding into the generic line.
        case audioTrackUnavailable
        /// The server presented a certificate this device does not trust and has not been told to
        /// accept. The only face here whose fix is a decision rather than a retry, which is why it
        /// exists rather than folding into the generic classified line.
        case certificateRejected
        /// The device ran out of storage for the segments the engine writes while it plays
        /// (AetherEngine#720). Neither the file nor the server is at fault, and the same title plays once
        /// space is freed, so the advice is about the device rather than a retry or another track.
        case storageFull
        /// The engine classified the failure but the host has no sentence for that kind. The viewer gets
        /// a translated line, and `identifier` carries the classification so a screenshot is still worth
        /// something in a bug report. It is deliberately NOT translated: it is a stable API token, and a
        /// bug report that names a different token per locale names nothing.
        case engineClassified(identifier: String)
        /// No classification at all: whatever sentence reached us is the best there is.
        case engineMessage
    }

    /// Which headline a face gets, since the same classification reads differently before the first
    /// frame ("could not start") and after it ("stopped").
    enum Context {
        case start
        case session
    }

    struct Trio: Equatable {
        let icon: String
        let title: String
        let message: String
    }

    /// `PlaybackErrorKind` is a string-backed struct so the engine can add kinds in a minor release
    /// without breaking a host that switches over it. Anything this build does not recognise therefore has
    /// to land on `.engineMessage`, never on a neighbouring face.
    static func face(for info: PlaybackErrorInfo?) -> Face {
        guard let info else { return .engineMessage }

        if info.kind == .sourceRefused {
            // The copy for a refusal names its status, so one that arrives without a status has nothing to
            // say that the engine's sentence does not say better.
            guard let status = info.underlyingCode else { return .engineMessage }
            switch status {
            case 401, 403: return .streamRefused(status: status)
            case 404, 410: return .streamNotFound
            default:       return .streamServerError(status: status)
            }
        }
        if info.kind == .sourceRateLimited { return .rateLimited }
        if info.kind == .sourceCertificateRejected { return .certificateRejected }
        if info.kind == .dolbyVisionRequiresHardware { return .dolbyVisionUnsupported }
        if info.kind == .liveSourceUnavailable { return .liveChannelUnavailable }
        if info.kind == .storageExhausted { return .storageFull }

        // `.nativeItemFailed` keeps the engine's sentence on purpose: it is AVFoundation's
        // `localizedDescription`, already in the device's language and more specific than anything the
        // host could write. Every other kind carries an engine-authored ENGLISH sentence, which in a
        // 26-language app is the one thing the viewer must not be handed, so those trade it for a
        // translated line plus the token.
        if info.kind == .nativeItemFailed { return .engineMessage }
        if info.kind == .audioBridgeProducedNoOutput || info.kind == .audioTrackSwitchFailed {
            return .audioTrackUnavailable
        }
        return .engineClassified(identifier: identifier(for: info))
    }

    /// `kind` plus whatever named the failure underneath, which is what a bug report can be searched on.
    static func identifier(for info: PlaybackErrorInfo) -> String {
        // Domain and code are one fact, so they stay one field: "NSURLErrorDomain -1001" is what a
        // search finds, "NSURLErrorDomain · -1001" is two things that have to be recombined by hand.
        let underlying = [info.underlyingDomain, info.underlyingCode.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " ")
        return underlying.isEmpty ? info.kind.rawValue : "\(info.kind.rawValue) · \(underlying)"
    }

    /// A live channel that never produced a frame reads as "unavailable", which is the honest verdict for a
    /// dead upstream and was the host's only live sentence before typed failures existed. Where the engine
    /// did type the failure, that naming is strictly better: a refused stream and a panel that is out of
    /// connection slots are both fixable, and neither is the channel being off the air.
    static func liveFace(for info: PlaybackErrorInfo?) -> Face {
        switch face(for: info) {
        // Both "no classification" and "classified, no host sentence" mean the host has nothing better
        // to say than the channel not coming up, and for live that IS the better sentence. The token
        // it costs is the price of not regressing the naming this already got right.
        case .engineMessage, .engineClassified:
            return .liveChannelUnavailable
        case let face:
            return face
        }
    }

    static func trio(for face: Face, engineMessage: String, context: Context = .session) -> Trio {
        switch face {
        case .streamRefused(let status):
            return Trio(
                icon: "lock.slash",
                title: String(
                    localized: "player.error.streamRefused.title",
                    defaultValue: "Stream refused"
                ),
                message: String(
                    format: String(
                        localized: "player.error.streamRefused.body",
                        defaultValue: "The server refused to deliver this stream (HTTP %lld). The item may not be shared with this account, or the session may have expired."
                    ),
                    status
                )
            )
        case .streamNotFound:
            return Trio(
                icon: "questionmark.folder",
                title: String(localized: "player.error.notFound.title", defaultValue: "Item unavailable"),
                message: String(
                    localized: "player.error.streamNotFound.body",
                    defaultValue: "The server no longer has this file. It may have been moved or removed from the library."
                )
            )
        case .streamServerError(let status):
            return Trio(
                icon: "server.rack",
                title: String(localized: "player.error.server.title", defaultValue: "Server error"),
                message: String(
                    format: String(
                        localized: "player.error.streamServerError.body",
                        defaultValue: "The server answered with HTTP %lld instead of the stream. Try again in a moment."
                    ),
                    status
                )
            )
        case .rateLimited:
            return Trio(
                icon: "antenna.radiowaves.left.and.right.slash",
                title: String(
                    localized: "player.error.rateLimited.title",
                    defaultValue: "Too many connections"
                ),
                message: String(
                    localized: "player.error.rateLimited.body",
                    defaultValue: "The source is not accepting another connection right now, usually because another device is already streaming from it. Wait a moment before trying again."
                )
            )
        case .dolbyVisionUnsupported:
            return Trio(
                icon: "questionmark.video",
                title: String(
                    localized: "player.error.dolbyVision.title",
                    defaultValue: "Dolby Vision not supported"
                ),
                message: String(
                    localized: "player.error.dolbyVision.body",
                    defaultValue: "This device cannot decode this Dolby Vision version. A different version of the file, or a device with Dolby Vision support, will play it."
                )
            )
        case .liveChannelUnavailable:
            return Trio(
                icon: "tv.slash",
                title: String(
                    localized: "player.error.liveUnavailable.title",
                    defaultValue: "Channel unavailable"
                ),
                message: String(
                    localized: "player.error.liveUnavailable.body",
                    defaultValue: "The server could not open this channel's stream. The channel's source may be offline. Try again later."
                )
            )
        case .audioTrackUnavailable:
            return Trio(
                icon: "speaker.slash",
                title: String(
                    localized: "player.error.audioTrack.title",
                    defaultValue: "Audio track unavailable"
                ),
                message: String(
                    localized: "player.error.audioTrack.body",
                    defaultValue: "This audio track could not be played. Start the title again and choose a different audio track."
                )
            )
        case .certificateRejected:
            return Trio(
                icon: "lock.trianglebadge.exclamationmark",
                title: String(
                    localized: "player.error.certificateRejected.title",
                    defaultValue: "Server identity not verified"
                ),
                message: String(
                    localized: "player.error.certificateRejected.body",
                    defaultValue: "This server presented a certificate this device does not trust, so the stream was not started. Add the server again in Settings to look at its certificate and accept it."
                )
            )
        case .storageFull:
            return Trio(
                icon: "externaldrive.badge.exclamationmark",
                title: String(
                    localized: "player.error.storageFull.title",
                    defaultValue: "Storage full"
                ),
                message: String(
                    localized: "player.error.storageFull.body",
                    defaultValue: "This device does not have enough free storage to prepare the video for playback. Free up some space, for example by removing apps you no longer use, and try again."
                )
            )
        case .engineClassified(let identifier):
            return Trio(
                icon: "exclamationmark.triangle",
                title: headline(context),
                message: String(
                    format: String(
                        localized: "player.error.engineClassified.body",
                        defaultValue: "The player could not continue with this video. If it keeps happening, include this code in a bug report: %@"
                    ),
                    identifier
                )
            )
        case .engineMessage:
            return Trio(
                icon: "exclamationmark.triangle",
                title: headline(context),
                message: engineMessage
            )
        }
    }

    /// Live trades the token for a better sentence, because "the channel did not come up" is what the
    /// viewer needs and a token is not. A bug report that says only that names nothing, though, so where
    /// a classification WAS swallowed, it comes back as a line under the sentence.
    static func appendingReportCode(to message: String, from info: PlaybackErrorInfo?) -> String {
        guard case .engineClassified(let identifier) = face(for: info) else { return message }
        let line = String(
            format: String(
                localized: "player.error.reportCode",
                defaultValue: "Code for a bug report: %@"
            ),
            identifier
        )
        return message.isEmpty ? line : "\(message)\n\n\(line)"
    }

    private static func headline(_ context: Context) -> String {
        switch context {
        case .start:
            return String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
        case .session:
            return String(localized: "player.error.playback.title", defaultValue: "Playback stopped")
        }
    }

    /// One diagnostic line per typed failure. The raw sentence stops being visible to the viewer, so this is
    /// the only place it survives, and the kind / status is what a bug report needs anyway.
    static func logLine(for info: PlaybackErrorInfo?, engineMessage: String) -> String {
        guard let info else { return "[EngineError] kind=none message=\(engineMessage)" }
        let status = info.underlyingCode.map(String.init) ?? "-"
        let domain = info.underlyingDomain ?? "-"
        return "[EngineError] kind=\(info.kind.rawValue) code=\(status) domain=\(domain) message=\(info.message)"
    }
}
