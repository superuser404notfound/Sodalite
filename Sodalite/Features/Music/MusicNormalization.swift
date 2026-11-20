import Foundation
import AetherEngine

/// Sodalite#242: plays every track at the loudness the server measured, from Jellyfin's
/// `NormalizationGain` / `AlbumNormalizationGain`. Track evens out every song; Album keeps the
/// loudness steps an album was mastered with and evens out albums against each other. Each mode
/// falls back to the other gain when its own is missing, the way Jellyfin's web player does.
enum MusicNormalization: String, CaseIterable, Sendable, Identifiable {
    case off, track, album

    var id: String { rawValue }
    var titleKey: String { "settings.playback.musicNormalization.\(rawValue)" }

    /// Which of the item's gains a pick used.
    enum Source: String, Sendable, Equatable {
        case track, album
        /// The item carries neither gain: the library's LUFS scan has not run.
        case none
    }

    struct Pick: Equatable, Sendable {
        /// Gain to hand the engine, nil for none.
        var gainDB: Double?
        var source: Source
    }

    func pick(trackGain: Double?, albumGain: Double?) -> Pick? {
        let track = trackGain.flatMap { $0.isFinite ? $0 : nil }
        let album = albumGain.flatMap { $0.isFinite ? $0 : nil }
        switch self {
        case .off:
            return nil
        case .track:
            if let track { return Pick(gainDB: track, source: .track) }
            if let album { return Pick(gainDB: album, source: .album) }
        case .album:
            if let album { return Pick(gainDB: album, source: .album) }
            if let track { return Pick(gainDB: track, source: .track) }
        }
        return Pick(gainDB: nil, source: .none)
    }

    func pick(for item: JellyfinItem) -> Pick? {
        pick(trackGain: item.normalizationGain, albumGain: item.albumNormalizationGain)
    }
}

/// What one track was asked to do, kept until the track is replaced so its log line can carry the
/// engine's account of it.
struct MusicNormalizationRecord: Equatable, Sendable {
    var itemID: String
    var mode: MusicNormalization
    var trackGain: Double?
    var albumGain: Double?
    var pick: MusicNormalization.Pick?

    init(item: JellyfinItem, mode: MusicNormalization) {
        itemID = item.id
        self.mode = mode
        trackGain = item.normalizationGain
        albumGain = item.albumNormalizationGain
        pick = mode.pick(for: item)
    }

    /// One line per track, written when it ends or is replaced. The item id rather than the title keeps
    /// library contents out of logs posted in issues. `chosen=0 (no gain on item)` points at a library
    /// whose LUFS scan has not run; `applied` below `requested` means the engine could not lift there.
    func logLine(report: NormalizationGainReport?) -> String {
        func db(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "nil" }
        var line = "[music] normalization: item=\(itemID) mode=\(mode.rawValue) "
            + "jellyfin=\(db(trackGain))/\(db(albumGain)) (track/album) "
        if let pick, pick.source != .none {
            line += "chosen=\(db(pick.gainDB)) (\(pick.source.rawValue))"
        } else {
            line += "chosen=0 (no gain on item)"
        }
        line += " " + (report?.summary ?? "applied=0 stage=none")
        return line
    }
}
