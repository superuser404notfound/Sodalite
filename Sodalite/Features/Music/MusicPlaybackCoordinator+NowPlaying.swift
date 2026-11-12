import Foundation
import MediaPlayer
import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AetherEngine

/// Native system Now-Playing for the music path.
///
/// The engine owns it (`ownsAudioNowPlaying`, set in `DependencyContainer`): the card, the clock and the
/// transport commands, on whichever audio host the track lands on (the AVPlayer host's own
/// `MPNowPlayingSession`, or the shared centers for the FFmpeg host). This file only supplies what the
/// engine cannot know: the track's identity and cover, and next/previous for the queue.
///
/// The cover slot is never empty: an empty one makes the session fall back to decoding the asset's OWN
/// embedded cover, and a corrupt one crashes MediaPlayer.
extension MusicPlaybackCoordinator {

    /// Stage the identity of the current track and hand the queue's next/previous to the engine.
    /// Clears the surface when there is no current item.
    func applyNowPlayingInfo() {
        guard let item = currentItem else {
            clearNowPlayingInfo()
            return
        }
        engine.setAudioNowPlayingInfo(baseNowPlayingDict(for: item))
        // Both stay live for the whole queue, as before: next on the last track stops, previous on the
        // first one restarts it. The engine calls them on the main actor.
        engine.setNowPlayingTrackCommands(
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() })
        loadArtwork(for: item)
    }

    /// Title/artist/album/mediaType + a GUARANTEED-valid artwork. Elapsed, rate and duration come from the engine.
    private func baseNowPlayingDict(for item: JellyfinItem) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
        info[MPMediaItemPropertyArtist] = item.trackArtistLine ?? ""
        info[MPMediaItemPropertyAlbumTitle] = item.albumArtist ?? ""
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        // ALWAYS fill the artwork slot: the real cover once loaded, else a placeholder. A non-empty, valid slot keeps
        // the auto-publishing session from falling back to decoding the asset's OWN embedded cover (a corrupt one
        // crashes MediaPlayer). The placeholder is shown only for the moment before the real cover resolves.
        if let art = cachedArtwork, cachedArtworkItemID == item.id {
            info[MPMediaItemPropertyArtwork] = art
        } else {
            info[MPMediaItemPropertyArtwork] = Self.placeholderArtwork
        }
        return info
    }

    /// Solid placeholder cover used whenever the real album art is missing or still loading, so the Now-Playing
    /// artwork slot is never empty. @Sendable handler (MediaPlayer requests the bitmap off the main actor). Built once.
    static let placeholderArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 600, height: 600)
        let image = PlatformImage.drawn(size: size, opaque: true) { context in
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            // Filled through the glyph's alpha rather than by tinting the symbol image: the two
            // frameworks tint one by different routes, and a fill clipped to the glyph is the same
            // picture on both.
            guard let glyph = PlatformImage.systemSymbol("music.note", pointSize: 220)?.cgImage
            else { return }
            let box = CGRect(
                x: (size.width - CGFloat(glyph.width)) / 2,
                y: (size.height - CGFloat(glyph.height)) / 2,
                width: CGFloat(glyph.width),
                height: CGFloat(glyph.height)
            )
            context.saveGState()
            context.clip(to: box, mask: glyph)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(box)
            context.restoreGState()
        }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }()

    func clearNowPlayingInfo() {
        engine.setAudioNowPlayingInfo([:])
        engine.setNowPlayingTrackCommands(next: nil, previous: nil)
        cachedArtwork = nil
        cachedArtworkItemID = nil
    }

    // MARK: - Artwork

    /// Resolve album-art URL (album image, track primary fallback), load off the main actor, merge
    /// into the live dictionary guarding against a track change mid-load. Caches so refreshes keep it.
    private func loadArtwork(for item: JellyfinItem) {
        let itemID = item.id
        nowPlayingArtworkItemID = itemID

        if cachedArtworkItemID == itemID, cachedArtwork != nil { return }

        guard let url = imageService.musicCoverURL(for: item, maxWidth: ImageWidth.cover) else { return }

        Task { [weak self] in
            // A half-written resize decodes into a half-drawn cover rather than into a failure, and
            // the lock screen would keep it. ImageFetch also drops the refused entry, so the next
            // track change is not served the same half file out of the HTTP cache (Sodalite#123).
            guard case .whole(let data) = await ImageFetch.load(URLRequest(url: url)),
                  let image = PlatformImage(data: data),
                  // Force-decode off-main. A corrupt cover (Jellyfin can serve a truncated embedded image:
                  // "Error -17102 decompressing image -- possibly corrupt") otherwise crashes MediaPlayer when
                  // it decodes the image lazily. nil = undecodable, so keep the already-published placeholder.
                  let decoded = await image.byPreparedForDisplay() else { return }

            await MainActor.run { [weak self] in
                guard let self, self.nowPlayingArtworkItemID == itemID else { return }
                // @Sendable is REQUIRED: MediaPlayer invokes this handler off the main actor (it requests the bitmap
                // via -[MPMediaItemArtwork jpegDataWithSize:] on its own thread). The MediaPlayer header does not
                // declare the handler @Sendable, so a plain closure silently inherits MainActor isolation and, in a
                // Swift 6 target, trips _dispatch_assert_queue_fail on that thread (Apple DTS forum 764874). `decoded`
                // is an immutable, already-force-decoded image, so the @Sendable capture is sound.
                let artwork = MPMediaItemArtwork(boundsSize: decoded.size) { @Sendable _ in decoded }
                self.cachedArtwork = artwork
                self.cachedArtworkItemID = itemID
                // Re-stage with the real cover in place of the placeholder.
                self.engine.setAudioNowPlayingInfo(self.baseNowPlayingDict(for: item))
            }
        }
    }
}
