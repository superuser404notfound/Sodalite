import Foundation
import MediaPlayer
import AVFoundation
import UIKit
import AetherEngine

/// Native system Now-Playing for the music path.
///
/// On tvOS 14+ a bare AVPlayer must own an `MPNowPlayingSession` to stay the active Now-Playing app
/// across a background pause: the SHARED info/command centers aren't reliably bound, so on pause
/// (rate 0) the system drops the app and stops delivering the play button (Apple forums 658311 /
/// 706656). The engine owns that session with `automaticallyPublishesNowPlayingInfo` ON (Apple's
/// documented bare-AVPlayer path, WWDC22 110338): the AVPlayer path hands its staged dict
/// (title/artist/album + a GUARANTEED-valid, @Sendable artwork) to the engine, which stamps it on
/// AVPlayerItem.nowPlayingInfo, and the session auto-derives elapsed/rate/state/duration from the
/// player. We always supply a valid artwork so the system never falls back to decoding the asset's
/// OWN embedded cover, which crashes on a corrupt one. externalMetadata is NOT used here, it is an
/// AVKit property the bare audio AVPlayer (no AVPlayerViewController) never surfaces.
///
/// The FFmpeg fallback has no AVPlayer/session, so infoCenter/commandCenter resolve to the shared defaults,
/// and it writes that shared center directly (no auto-publisher there).
/// MPRemoteCommandCenter does NOT guarantee main-thread delivery on tvOS (it dispatches on a background
/// MediaPlayer queue), so each handler returns its status synchronously and hops the actual @MainActor work to
/// the main actor via `Task { @MainActor }`. Assuming main (MainActor.assumeIsolated in the handler body)
/// crashed with dispatch_assert_queue_fail when a command arrived off-main during playback.
extension MusicPlaybackCoordinator {

    /// Shared center for the FFmpeg fallback only. The AVPlayer/session path stamps AVPlayerItem.nowPlayingInfo
    /// (via the engine) and auto-publishes, so every use of this shared default is gated on `audioNowPlayingSession == nil`.
    private var infoCenter: MPNowPlayingInfoCenter {
        MPNowPlayingInfoCenter.default()
    }

    /// Command center for transport handlers: the active session's own center, else the shared default.
    private var commandCenter: MPRemoteCommandCenter {
        engine.audioNowPlayingSession?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
    }

    /// Build + publish the now-playing dictionary, register remote commands (once), kick an async
    /// artwork load. Clears the surface when there is no current item.
    func applyNowPlayingInfo() {
        guard let item = currentItem else {
            clearNowPlayingInfo()
            return
        }

        // Register transport handlers once, on the session's command center (the binding tvOS needs).
        registerRemoteCommandsIfNeeded()

        // AVPlayer path: hand the staged dict (with a guaranteed-valid artwork) to the engine, which stamps it on
        // AVPlayerItem.nowPlayingInfo; the auto-publishing session merges in elapsed/rate/duration. NO manual write
        // to MPNowPlayingInfoCenter, and NO externalMetadata (an AVKit property the bare audio AVPlayer never surfaces).
        if engine.audioNowPlayingSession != nil {
            engine.setAudioNowPlayingInfo(baseNowPlayingDict(for: item))
            loadArtwork(for: item)
            return
        }

        // FFmpeg fallback (Opus/Vorbis: no AVPlayer/session): manual write to the shared center.
        var info = baseNowPlayingDict(for: item)
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // NOTE: deliberately NOT setting playbackState (macOS-only; tvOS reads PlaybackRate for play/pause).
        infoCenter.nowPlayingInfo = info
        loadArtwork(for: item)
    }

    /// Title/artist/album/mediaType + a GUARANTEED-valid artwork, shared by both paths. The session path (auto-publish)
    /// leaves elapsed/rate/duration to the system; the FFmpeg path appends them before writing the shared center.
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
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cfg = UIImage.SymbolConfiguration(pointSize: 220, weight: .regular)
            if let symbol = UIImage(systemName: "music.note", withConfiguration: cfg)?
                .withTintColor(UIColor(white: 0.5, alpha: 1), renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2,
                                        y: (size.height - symbol.size.height) / 2))
            }
        }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }()

    /// Refresh just elapsed + rate on the EXISTING entry (no rebuild / artwork reload / log), on the
    /// timer so the system keeps a live entry: shows the Home overlay promptly (not lagging our last
    /// write), keeps it alive across a pause (stale entries get dropped), and moves the scrubber.
    func refreshNowPlayingElapsed() {
        // On the session path the engine drives elapsed/rate from the player; only the FFmpeg fallback needs this.
        guard engine.audioNowPlayingSession == nil, currentItem != nil else { return }
        let center = infoCenter
        guard var info = center.nowPlayingInfo else {
            // No entry yet (first publish): build the full one.
            applyNowPlayingInfo()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        center.nowPlayingInfo = info
    }

    func clearNowPlayingInfo() {
        // Clear the AVPlayer path's staged per-item dictionary (no-op if no audio host).
        engine.setAudioNowPlayingInfo([:])
        // The session auto-clears on stop; only the FFmpeg fallback's shared-center entry needs an explicit nil.
        if engine.audioNowPlayingSession == nil {
            infoCenter.nowPlayingInfo = nil
        }
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

        guard let url = imageService.musicCoverURL(for: item, maxWidth: 600) else { return }

        Task { [weak self] in
            // A half-written resize decodes into a half-drawn cover rather than into a failure, and
            // the lock screen would keep it. ImageFetch also drops the refused entry, so the next
            // track change is not served the same half file out of the HTTP cache (Sodalite#123).
            guard case .whole(let data) = await ImageFetch.load(URLRequest(url: url)),
                  let image = UIImage(data: data),
                  // Force-decode off-main. A corrupt cover (Jellyfin can serve a truncated embedded image:
                  // "Error -17102 decompressing image -- possibly corrupt") otherwise crashes MediaPlayer when
                  // it decodes the image lazily. nil = undecodable, so keep the already-published placeholder.
                  let decoded = await image.byPreparingForDisplay() else { return }

            await MainActor.run { [weak self] in
                guard let self, self.nowPlayingArtworkItemID == itemID else { return }
                // @Sendable is REQUIRED: MediaPlayer invokes this handler off the main actor (it requests the bitmap
                // via -[MPMediaItemArtwork jpegDataWithSize:] on its own thread). The MediaPlayer header does not
                // declare the handler @Sendable, so a plain closure silently inherits MainActor isolation and, in a
                // Swift 6 target, trips _dispatch_assert_queue_fail on that thread (Apple DTS forum 764874). `decoded`
                // is an immutable, already-force-decoded UIImage, so the @Sendable capture is sound.
                let artwork = MPMediaItemArtwork(boundsSize: decoded.size) { @Sendable _ in decoded }
                self.cachedArtwork = artwork
                self.cachedArtworkItemID = itemID
                if self.engine.audioNowPlayingSession != nil {
                    // AVPlayer path: re-stamp the dict with the real cover (replacing the placeholder) on the item.
                    self.engine.setAudioNowPlayingInfo(self.baseNowPlayingDict(for: item))
                } else {
                    // FFmpeg fallback: merge artwork into the shared center.
                    guard var info = self.infoCenter.nowPlayingInfo else { return }
                    info[MPMediaItemPropertyArtwork] = artwork
                    self.infoCenter.nowPlayingInfo = info
                }
            }
        }
    }

    // MARK: - Remote commands

    /// Bind transport handlers to the command center, re-binding whenever the RESOLVED center changes.
    /// The engine routes per codec: AVPlayer-decodable audio -> session center, Opus/Vorbis -> FFmpeg
    /// shared center. A once-only registration bound to whichever was live first, so in a mixed queue
    /// the other path had a target-less center and Control Center / Siri Remote went dead.
    /// Identity-tracked so same-center calls stay no-ops (session is persistent, per-track re-register is churn).
    private func registerRemoteCommandsIfNeeded() {
        let center = commandCenter
        let centerID = ObjectIdentifier(center)
        guard registeredCommandCenterID != centerID else { return }
        registeredCommandCenterID = centerID

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] playCommand fired (isPlaying=\(self.isPlaying), hasItem=\(self.currentItem != nil))")
                self.resume()
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] pauseCommand fired (isPlaying=\(self.isPlaying))")
                self.engine.pause()
            }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] togglePlayPauseCommand fired (isPlaying=\(self.isPlaying))")
                self.togglePlayPause()
            }
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] nextTrackCommand fired (hasNext=\(self.hasNext), index=\(self.currentIndex))")
                self.next()
            }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] previousTrackCommand fired (hasPrevious=\(self.hasPrevious), index=\(self.currentIndex))")
                self.previous()
            }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] changePlaybackPositionCommand fired (pos=\(Int(position))s)")
                self.seek(to: position)
            }
            return .success
        }

        LogTap.shared.note("[NowPlaying] shared remote command handlers registered")
    }
}
