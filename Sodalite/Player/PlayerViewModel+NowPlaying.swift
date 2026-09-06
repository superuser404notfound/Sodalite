import Foundation
import AVFoundation
import UIKit
import AetherEngine

/// System Now Playing wiring via `AVPlayerItem.externalMetadata`. AVKit's internal Now Playing session (from `showsPlaybackControls = true`) reads title/description/artwork from externalMetadata and publishes to MPNowPlayingInfoCenter; the host VC suppresses visible chrome (`playbackControlsIncludeTransportBar/InfoViews = false`) but keeps AVKit's backend for privileged features (AirPods auto-detect, Enhance Dialogue, Reduce Loud Sounds, synchronized Atmos).
///
/// Flow: `stageInitialNowPlayingMetadata` (BEFORE engine.load) hands title/description to `setExternalMetadata`, which the engine applies before replaceCurrentItem so AVKit's first asset-metadata read catches them; `refreshExternalMetadataWithArtwork` (AFTER load) fetches the cover and re-stages, written to the live item. Across audio-switch reloads the engine replays pendingExternalMetadata onto the fresh NativeAVPlayerHost, so title/cover survive without host wiring.
extension PlayerViewModel {

    // MARK: - Pre-load externalMetadata stage

    /// Build static externalMetadata (title, description) and stash on the engine BEFORE `engine.load`, so it's applied before replaceCurrentItem and the first asset-metadata read catches it.
    func stageInitialNowPlayingMetadata() {
        let items = buildExternalMetadataItems(artworkData: nil)
        LogTap.shared.note("[NowPlaying] stage id=\(item.id) items=\(items.count)")
        player.setExternalMetadata(items)
    }

    // MARK: - Remote commands (documented-API dead end)

    /// CC 10s skip buttons appear in the widget but dispatch nowhere hookable from user code. Verified-dead paths (do not reattempt):
    ///   - `MPRemoteCommandCenter.shared().skipForwardCommand` dormant; CC routes to AVKit's per-session command center, not shared (c54fcb7).
    ///   - `AVPlayerViewControllerDelegate.skipToNextItem/skipToPreviousItem` with `.skipItem` never fire from CC (8d8e154).
    ///   - `timeToSeekAfterUserNavigatedFrom` fires for scrubs but NOT skip-by-interval presses (7ed793d / cd890d5).
    ///   - Explicit `MPNowPlayingSession(players:)` coexists with AVKit's but still isn't routed CC skip presses (cd890d5).
    ///   - Manual `MPNowPlayingInfoCenter.nowPlayingInfo` writes crash with `_dispatch_assert_queue_fail` on both NWConnection and BSD-socket HLS loopback (962292d).
    ///   - `AVAssetResourceLoaderDelegate` for HLS segments rejected by AVPlayer (Apple Forum 113063).
    /// Only path left is private API (`_nowPlayingSession` via KVC), not worth the reject risk. Everything else (title/cover/scrub/play-pause/AirPods/Enhance Dialogue/Reduce Loud Sounds/Atmos) works.

    // MARK: - Post-load artwork refresh

    /// Async-fetch the primary image and re-stage externalMetadata with artwork; engine writes to the live item, AVKit re-reads on the next publish tick. Failures leave title-only metadata in place.
    func refreshExternalMetadataWithArtwork() async {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id)")
            return
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        let request = URLRequest(url: url, timeoutInterval: 5.0)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            guard ImagePayload.isComplete(data),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                LogTap.shared.note("[NowPlaying] artwork: decode/re-encode failed")
                return
            }
            await MainActor.run {
                let items = self.buildExternalMetadataItems(artworkData: jpeg)
                self.player.setExternalMetadata(items)
            }
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - External metadata builder

    private func buildExternalMetadataItems(artworkData: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(makeStringItem(.commonIdentifierTitle, nowPlayingTitle))
        if let series = nowPlayingSeriesLine {
            // Both identifiers carry the series: iTunes subtitle feeds the tvOS info panel's second line; the artist item is what AVKit forwards to MediaRemote's artist slot = the iPhone widget's second line (device-verified the subtitle item alone does NOT surface there).
            items.append(makeStringItem(.iTunesMetadataTrackSubTitle, series))
            items.append(makeStringItem(.commonIdentifierArtist, series))
        }
        if let descriptionLine = displayDescriptionLine {
            items.append(makeStringItem(.commonIdentifierDescription, descriptionLine))
        }
        if let data = artworkData {
            items.append(makeArtworkItem(data: data))
        }
        return items
    }

    /// Now-Playing title line. Episodes: "S2, E5 · Title", with series on the second line via artist/subtitle items (music convention: title = piece, artist = owner; issue #15 follow-up). Movies keep their plain title.
    private var nowPlayingTitle: String {
        guard item.type == .episode else { return item.name }
        let label = EpisodeMetadataFormatter.label(season: item.parentIndexNumber,
                                                   episode: item.indexNumber,
                                                   title: item.name)
        return label.isEmpty ? item.name : label
    }

    /// Series name for the second Now-Playing line. Episodes only;
    /// movies have nothing useful to put there.
    private var nowPlayingSeriesLine: String? {
        guard item.type == .episode, let series = item.seriesName, !series.isEmpty else {
            return nil
        }
        return series
    }

    private var displayDescriptionLine: String? {
        if item.type == .episode {
            // Title + subtitle already carry series and season/episode; use the description slot for the synopsis instead of repeating them.
            // Sodalite#50: AVKit metadata cannot be blurred, so a veiled synopsis is dropped instead.
            guard !spoilerPolicy.isHidden(item) else { return nil }
            if let overview = item.overview, !overview.isEmpty {
                return overview
            }
            return nil
        }
        if let year = item.productionYear {
            return "(\(year))"
        }
        return nil
    }

    private func makeStringItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = identifier
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    private func makeArtworkItem(data: Data) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.dataType = "public.jpeg"
        return m
    }

    private func primaryImageURL() -> URL? {
        guard let base = playbackService.baseURL?.absoluteString else { return nil }
        // Series poster (Primary) for episodes when the Appearance setting prefers it: a portrait poster fills the square CC artwork slot better than the episode's landscape still.
        if DependencyContainer.shared.appearancePreferences.nowPlayingUsesSeriesPoster,
           item.type == .episode, let seriesId = item.seriesId {
            let tagParam = item.seriesPrimaryImageTag.map { "&tag=\($0)" } ?? ""
            return URL(string: "\(base)/Items/\(seriesId)/Images/Primary?maxWidth=800&quality=85\(tagParam)")
        }
        if let tag = item.imageTags?.primary {
            return URL(string: "\(base)/Items/\(item.id)/Images/Primary?tag=\(tag)&maxWidth=800&quality=85")
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return URL(string: "\(base)/Items/\(item.id)/Images/Backdrop?tag=\(tag)&maxWidth=800&quality=85")
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return URL(string: "\(base)/Items/\(seriesId)/Images/Backdrop?tag=\(tag)&maxWidth=800&quality=85")
        }
        return nil
    }
}
