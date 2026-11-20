import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#247: the VOD subtitle menu takes in the container tracks the engine found and Jellyfin's
/// PlaybackInfo does not list, and changes nothing where Jellyfin's list is complete.
@MainActor
struct EngineSubtitleInventoryTests {

    private func stream(index: Int, type: MediaStreamType = .subtitle, external: Bool = false,
                        codec: String? = "subrip", lang: String? = "eng",
                        title: String? = nil) -> MediaStream {
        MediaStream(index: index, type: type, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: nil,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    private func track(_ id: Int, codec: String = "subrip", lang: String? = "eng",
                       name: String = "", forced: Bool = false, sdh: Bool = false,
                       external: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: name, codec: codec, language: lang, isDefault: false,
                  isForced: forced, isHearingImpaired: sdh, isExternal: external)
    }

    @Test("a complete Jellyfin list comes back unchanged")
    func completeListUnchanged() {
        // One external .srt numbered first, so the embedded tracks sit one index past their container's.
        let source = [stream(index: 0, external: true, lang: "ger"),
                      stream(index: 1, type: .video, codec: "h264", lang: nil),
                      stream(index: 3, lang: "eng"), stream(index: 4, lang: "fre")]
        let engine = [track(2, lang: "eng"), track(3, lang: "fre"),
                      track(AetherEngine.externalSubtitleTrackIDBase, lang: "ger", external: true)]
        let merged = EngineSubtitleInventory.mergedStreams(sourceStreams: source, engineTracks: engine)
        #expect(merged.map(\.index) == PlayerViewModel.dedupedSubtitleStreams(from: source).map(\.index))
    }

    @Test("a track Jellyfin does not list joins the menu and selects the engine's track")
    func missingTrackJoins() {
        let source = [stream(index: 1, type: .video, codec: "h264", lang: nil), stream(index: 2, lang: "eng")]
        let engine = [track(2, lang: "eng"), track(3, codec: "hdmv_pgs_subtitle", lang: "spa", sdh: true)]
        let merged = EngineSubtitleInventory.mergedStreams(sourceStreams: source, engineTracks: engine)
        #expect(merged.map(\.index) == [2, EngineSubtitleInventory.menuIndexBase + 3])
        let added = merged[1]
        #expect(added.language == "spa")
        #expect(added.codec == "hdmv_pgs_subtitle")
        #expect(added.isHearingImpaired == true)
        #expect(added.isExternal == false)
        #expect(PlayerViewModel.embeddedEngineTrackID(forJellyfinIndex: added.index, in: source) == 3)
    }

    @Test("with no subtitle metadata at all, every container track the engine found is listed")
    func emptyServerList() {
        let engine = [track(2, lang: "eng"), track(3, lang: "ger", forced: true)]
        let merged = EngineSubtitleInventory.mergedStreams(sourceStreams: [], engineTracks: engine)
        #expect(merged.map(\.index) == [EngineSubtitleInventory.menuIndexBase + 2,
                                        EngineSubtitleInventory.menuIndexBase + 3])
        #expect(merged[1].isForced == true)
    }

    @Test("sidecars and rendition ids are not container tracks; A53 captions are")
    func onlyContainerTracks() {
        let engine = [track(AetherEngine.externalSubtitleTrackIDBase, external: true),
                      track(200_000, codec: "webvtt"),
                      track(AetherEngine.a53ClosedCaptionTrackID, codec: "eia_608", lang: nil,
                            name: "Closed Captions")]
        let merged = EngineSubtitleInventory.mergedStreams(sourceStreams: [], engineTracks: engine)
        #expect(merged.map(\.index) == [EngineSubtitleInventory.menuIndexBase + AetherEngine.a53ClosedCaptionTrackID])
        #expect(TrackDisplayFormatter.subtitleStreamDisplayName(for: merged[0]) == "Closed Captions")
    }

    @Test("an added track goes through the menu's dedupe like a listed one")
    func addedTrackIsDeduped() {
        let source = [stream(index: 2, lang: "eng")]
        let merged = EngineSubtitleInventory.mergedStreams(
            sourceStreams: source, engineTracks: [track(2, lang: "eng"), track(5, lang: "eng")])
        #expect(merged.map(\.index) == [2])
    }

    @Test("a Jellyfin index never reads as an engine-only one")
    func jellyfinIndicesStayJellyfin() {
        #expect(EngineSubtitleInventory.engineTrackID(forMenuIndex: 0) == nil)
        #expect(EngineSubtitleInventory.engineTrackID(forMenuIndex: 42) == nil)
        #expect(EngineSubtitleInventory.engineTrackID(
            forMenuIndex: EngineSubtitleInventory.menuIndex(forEngineTrackID: 7)) == 7)
    }
}
