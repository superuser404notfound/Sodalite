import Foundation
import Testing
import AetherEngine
@testable import Sodalite

/// Sodalite#242: which gain a track plays at, and the line it leaves in the diagnostic log.
struct MusicNormalizationTests {

    private func track(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"a1","Name":"Song","Type":"Audio"\#(json)}"#.utf8))
    }

    @Test func jellyfinsGainsDecode() throws {
        let item = try track(#","NormalizationGain":-7.9,"AlbumNormalizationGain":-6.2"#)
        #expect(item.normalizationGain == -7.9)
        #expect(item.albumNormalizationGain == -6.2)
        #expect(try track("").normalizationGain == nil)
    }

    @Test func eachModeFallsBackToTheOtherGain() {
        #expect(MusicNormalization.track.pick(trackGain: -7.9, albumGain: -6.2)
                == .init(gainDB: -7.9, source: .track))
        #expect(MusicNormalization.album.pick(trackGain: -7.9, albumGain: -6.2)
                == .init(gainDB: -6.2, source: .album))
        #expect(MusicNormalization.track.pick(trackGain: nil, albumGain: -6.2)
                == .init(gainDB: -6.2, source: .album))
        #expect(MusicNormalization.album.pick(trackGain: 3.1, albumGain: nil)
                == .init(gainDB: 3.1, source: .track))
    }

    @Test func offAndMissingGains() {
        #expect(MusicNormalization.off.pick(trackGain: -7.9, albumGain: -6.2) == nil)
        #expect(MusicNormalization.track.pick(trackGain: nil, albumGain: .nan)
                == .init(gainDB: nil, source: .none))
    }

    @Test func theLogLineCarriesBothHalves() throws {
        let item = try track(#","NormalizationGain":-7.9,"AlbumNormalizationGain":-6.2"#)
        let record = MusicNormalizationRecord(item: item, mode: .track)
        let report = NormalizationGainReport(requestedDB: -7.9, appliedDB: -7.9, host: .avPlayer, stage: .tap)
        #expect(record.logLine(report: report)
                == "[music] normalization: item=a1 mode=track jellyfin=-7.9/-6.2 (track/album) chosen=-7.9 (track) "
                + "requested=-7.9 applied=-7.9 host=AVPlayer stage=tap limiter=none")
    }

    @Test func anUnscannedLibraryShowsInTheLine() throws {
        let record = MusicNormalizationRecord(item: try track(""), mode: .album)
        #expect(record.logLine(report: nil)
                == "[music] normalization: item=a1 mode=album jellyfin=nil/nil (track/album) chosen=0 (no gain on item) "
                + "applied=0 stage=none")
    }

    @Test func theModeTravelsBetweenProfilesAndDevices() {
        let suite = "MusicNormalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults().removePersistentDomain(forName: suite + ".t")
        }
        let source = PlaybackPreferences(store: defaults)
        source.musicNormalization = .album
        let target = PlaybackPreferences(store: UserDefaults(suiteName: suite + ".t")!)
        ProfilePlaybackPayload(collecting: source, stamp: .now).apply(to: target)
        #expect(target.musicNormalization == .album)
        #expect(PlaybackPreferences(store: defaults).musicNormalization == .album)
    }
}
