<p align="center">
  <img src=".github/sodalite-logo.png" alt="Sodalite" width="180">
</p>

<h1 align="center">Sodalite</h1>

<p align="center">
  <b>Your Jellyfin library <i>and</i> Seerr, together on Apple TV.</b><br>
  Native tvOS, instant playback, real HDR, real Dolby Atmos.<br>
  Browse what you own. Request what's missing. Tune into live TV.<br>
  Without ever leaving the couch.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tvOS-26%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-GPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
  <img src="https://img.shields.io/badge/languages-26-blue">
  <img src="https://img.shields.io/badge/status-public%20beta-orange">
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

> 🧪 **Public Beta is open.** Install via TestFlight: **https://testflight.apple.com/join/nWeQzmBX**
> See [BETA.md](BETA.md) for what to focus on and how to report bugs.

---

## Screenshots

<table>
  <tr>
    <td width="50%"><a href=".github/media/screenshot-home.jpg"><img src=".github/media/screenshot-home.jpg" alt="Home: Continue Watching, Next Up and Favorites rows"></a></td>
    <td width="50%"><a href=".github/media/screenshot-tv.jpg"><img src=".github/media/screenshot-tv.jpg" alt="Live TV: On Now and Series rows in the overview tab"></a></td>
  </tr>
  <tr>
    <td align="center"><b>Home</b></td>
    <td align="center"><b>Live TV</b> (overview)</td>
  </tr>
  <tr>
    <td width="50%"><a href=".github/media/screenshot-catalog.jpg"><img src=".github/media/screenshot-catalog.jpg" alt="Catalog: Seerr Discover with Trending and Upcoming Movies"></a></td>
    <td width="50%"><a href=".github/media/screenshot-search.jpg"><img src=".github/media/screenshot-search.jpg" alt="Search: library results and matching catalog titles"></a></td>
  </tr>
  <tr>
    <td align="center"><b>Catalog</b> (Seerr browse &amp; request)</td>
    <td align="center"><b>Search</b></td>
  </tr>
  <tr>
    <td width="50%"><a href=".github/media/screenshot-music.jpg"><img src=".github/media/screenshot-music.jpg" alt="Music: album track list with play and shuffle"></a></td>
    <td width="50%"><a href=".github/media/screenshot-settings.jpg"><img src=".github/media/screenshot-settings.jpg" alt="Settings: profile, rows, playback and appearance"></a></td>
  </tr>
  <tr>
    <td align="center"><b>Music</b></td>
    <td align="center"><b>Settings</b></td>
  </tr>
</table>

---

## Two services, one remote

Sodalite brings **Jellyfin and Seerr together in the same UI** on Apple TV. Watch what's already on your server. Spot something on a trending row that isn't there yet? Request it from inside the app, and Seerr handles the rest.

No more switching to a phone, opening a web UI, or pinging your homelab admin. Single sign-on, one focus-driven interface, the full library plus request loop on the TV where you actually watch.

## Open source, end to end

Sodalite is open from end to end. Every byte that touches your server is in this repo, your auth tokens stay in your Keychain, and there's no telemetry, no analytics, no third-party SDK phoning home.

Licensed under **GPL-3.0 with an Apple Store / DRM Exception**. Fork it, study it, build your own version, but no one can take it private. Modifications must stay open. The exception clause in the LICENSE keeps the App Store and TestFlight distribution paths legally clean. The video stack underneath ([AetherEngine](https://github.com/superuser404notfound/AetherEngine)) is **LGPL-3.0** with the same Apple Store exception, so the engine can be reused in other apps while engine-level improvements flow back to the community. Both are auditable, buildable from source, and free of any vendor lock-in. Self-host the server, self-build the client, the whole loop is yours.

## Built natively for tvOS

Sodalite is built natively from the ground up: SwiftUI on top, a custom video engine underneath, and the same HIG patterns Apple uses for TV+: focus engine, Siri Remote gestures, transport bar, info panel. Plays the file directly from your server in almost every case, no transcoding required, and live channels stream straight from their source where possible.

The Seerr integration isn't a tacked-on link to a web view. It's a first-class part of the app, with its own browse rows, request flow, and status tracking right next to your library.

## Features

### 📚 Browse & discover
- **Server discovery**: finds Jellyfin on your network automatically, or add manually
- **Multiple servers**: keep several Jellyfin servers in the app and switch between them without logging out; pick or add one from above your profile list, manage the full list in Settings → Servers
- **Home**: Continue Watching, Next Up, a separate Latest row for each of your libraries, plus a My Media row to jump straight into any library; every row can be toggled and reordered, and Continue Watching and Next Up can optionally merge into a single row
- **Library**: Movies, Series, Collections with poster grids, instant filtering and an All / Unwatched / Watched watch-status filter on every grid
- **Series view**: season picker, episode list, "Up Next" highlighting
- **Playlists**: your Jellyfin playlists get their own Home row and a detail page that plays through in order
- **Search**: across your whole server, results as you type
- **Image caching & prefetching**: posters and backdrops load before you focus them
- **Delete from the app**: remove movies, series, or individual seasons from your library, with optional cleanup of matching Radarr / Sonarr entries when Jellyseerr is connected
- **Rich detail pages**: cast, ratings, where-to-watch and more-like-this on catalog titles; tagline, director, writer and studios on your own library
- **Title logos & synopses**: detail screens float the title logo over the backdrop and show full episode synopses, both toggleable in Appearance settings
- **Full-bleed backdrops**: artwork shines through the whole detail page and dims as you scroll; titles without backdrop art get an ambient poster fill instead of a grey plate
- **Watched tracking**: mark movies, episodes, seasons or whole series as watched or unwatched, with progress badges across Home and detail screens
- **Cast & filmography**: tap any cast member to see their photo, biography and full filmography, then jump straight to a title in your library or request it from the catalog

### 🎬 Watch
- **Direct Play** for almost every codec on your server: H.264, HEVC, HEVC Main10, AV1, VP9, VP8, MPEG-4 Part 2 (XVID / DIVX), MPEG-2, VC-1. Containers: MKV, MP4, MOV, AVI, MPEG-TS, M2TS, VOB, 3GP, WebM, OGG, FLV. Server-side transcoding stays reserved for fringe codecs (WMV3, Theora, RealVideo).
- **HDR10, HDR10+, Dolby Vision, HLG**: auto-detected, sent through with full color metadata. HDR10+ streams forward per-frame ST 2094-40 dynamic metadata so HDR10+ TVs apply the source's tone-mapping curves; Dolby Vision streams switch DV-capable TVs into Dolby Vision mode for Profile 5, 8.1 and 8.4 (Profile 7 is converted to single-layer 8.1 on device so it engages DV too): Profile 5 signals via a bare `dvh1` track tag, while 8.1 and 8.4 carry `dvh1` in `SUPPLEMENTAL-CODECS` on an `hvc1` base. The display switches to the matching HDR mode automatically (Match Content).
- **Dolby Atmos** via EAC3+JOC, wrapped as Dolby MAT 2.0 so your AVR's Atmos light actually comes on
- **Multichannel surround**: 5.1, 7.1 with correct channel layout
- **Resume** from where you left off, on any device
- **Restart from the beginning**: a dedicated button on movies, series and episodes to play from the start instead of resuming
- **Pick your source**: when a title has more than one version on your server (different rips, resolutions or editions), a picker lets you choose which one to play before playback starts, on both movies and episodes
- **Shuffle a series**: a shuffle button on series detail queues random episodes across every season
- **Trailers**: play a title's local trailer straight from your server with a dedicated button on the detail page
- **Intro skip**: auto-detected from your Jellyfin server, optional one-tap skip
- **Next episode**: auto-play with countdown, or just an overlay; configurable
- **Subtitles, all formats, client-side**: text codecs (SubRip, ASS, SSA, WebVTT, mov_text) decoded inline in AetherEngine as packets flow through the demuxer, no server extraction lag on first hit. Bitmap subtitles (PGS, HDMV PGS, DVB, DVD) rendered as native images at the right position on the frame, no more relying on the server having Tesseract installed for Blu-ray rips. Sidecar `.srt` / `.ass` / `.vtt` files parsed by FFmpeg as well. In-band CEA-608 closed captions (the `eia_608` caption track some streams and rips carry) are decoded on-device too and appear in the subtitle menu like any other track. Styled ASS / SSA rendering keeps the original fonts, colors and positioning, for both embedded and external sidecar tracks (toggle between styled and plain text in Playback settings). Track switching mid-playback, with auto-resolution against your preferred audio / subtitle language.
- **Subtitle search & download**: when your server is missing the right track, search and download subtitles from inside the player. Files that match by content hash get a badge so you know they line up, and ones you added can be removed with a long press.
- **Dual subtitles**: show a second simultaneous subtitle track above the first, for example the original language plus a translation. Pick a secondary track from the Secondary section at the top of the subtitle menu (text tracks only).
- **Audio track switcher**: pick the language or surround mix you want, mid-playback
- **Scrub preview**: thumbnails of the exact frame as you scrub, floating above the playhead, generated on-device by AetherEngine straight from the video so they land on the precise frame and work even when your server has no trickplay images prepared. An optional setting lets you prefer your server's pre-generated trickplay images instead (decode-free, lighter on older Apple TVs), falling back to on-device when the server has none
- **Custom player UI**: a hand-built transport bar and info panel on top of our own video engine, matching the gestures and feel of the Apple TV+ player without using the system player
- **Stats for Nerds overlay**: optional info panel during playback. Static section shows container, video codec / range / framerate / bitrate / decoder, audio codec / channels / bitrate / decoder, subtitle codec. Live section refreshes at 1 Hz with instant + average bitrate from the demuxer, forward buffer + cached MB, network throughput, dropped frames (native AVPlayer) or observed FPS (software AV1), plus a colour-coded A/V sync gap. A second toggle adds an Engine Diagnostics deep-dive (producer restarts, RSS, demuxer / muxer / audio-bridge bytes, server traffic) for troubleshooting. Enable in Settings → Playback → Advanced.
- **iPhone Control Center skip**: 10-second forward and backward skip buttons in the iPhone's Now Playing widget route through to the engine via `MPRemoteCommandCenter`, App Store compliant (no private API). Useful when the Siri Remote is across the room.

### 📺 Live TV & DVR
- **Overview tab**: Live TV opens on a category-based overview of what's on right now, with rows mirroring the native Jellyfin guide, before you drop into the full grid
- **Programme guide**: full EPG grid with a sticky channel column, wall-clock time ruler, live now-line and current-program highlighting; tap a program for info, watch and record actions
- **Channel favorites**: star channels in the guide, favorites sort to the top
- **Timeshift**: pause live TV, scrub back up to 10 minutes with on-device frame previews, snap back with Return to Live
- **Recordings & timers**: record a program or a whole series from the guide, manage scheduled timers, and play finished or still-recording shows
- **Direct from the source**: most channels play straight from their upstream, starting in seconds with no server transcoding, with automatic fallback through Jellyfin when a source needs it
- **Same engine as movies**: H.264 / HEVC channels ride the native pipeline, MPEG-2 / VC-1 and friends decode in software, and dead sources fail fast with a clear message instead of an endless spinner

### 🎵 Listen
- **Music library**: browse your Jellyfin music by album and play it back through the same engine, with a native tvOS Now Playing screen, cover art and scrubbing

### 📨 Request what's missing
- **Seerr integration**: browse trending and popular media right inside the app
- **One-tap requests** for movies and full series
- **Track status**: see what's been approved, declined, or is already downloading
- **Honest availability**: cross-checks your Jellyfin library so a title (or single season) deleted in Radarr / Sonarr shows as gone, not a stale "available", and stays re-requestable
- **Single sign-on**: log in once, Sodalite handles your Seerr session
- **Admin view**: with Jellyseerr admin permissions, approve, decline, edit, or delete any user's request right from the All Requests tab

### 🌍 Personal
- **Parental controls**: set a Guardian PIN to protect profiles and lock changes to settings, servers and profiles; a locked device returns to the profile picker on a cold start and gated actions ask for the PIN first, with recovery via your Jellyfin password
- **Watch Stats**: a Settings screen with your viewing totals, movies and episodes watched, completion rate, estimated hours, top genres, most-rewatched and recently-watched titles, all aggregated client-side from standard Jellyfin data
- **26 languages**: German, English, Spanish, French, Italian, Japanese, Korean, Norwegian, Dutch, Polish, Portuguese (BR + PT), Russian, Swedish, Simplified + Traditional Chinese, Turkish, Ukrainian, Czech, Slovak, Croatian, Finnish, Greek, Hungarian, Romanian, Danish
- **Dark, minimal design** built for living rooms, not for desks
- **Appearance options**: choose how Continue Watching and Now Playing artwork looks (episode still, backdrop or series thumb), set card size, toggle title logos, plus an accent color with the Supporter Pack
- **Liquid Glass** UI accents on tvOS 26+
- **Siri Remote optimized**: touch surface scrubbing, click for play/pause, swipe gestures throughout

## Built on

Sodalite is a thin native shell over a custom video stack: Apple's frameworks plus a Swift package that handles the formats Apple's own player can't on its own.

| Component | Technology |
|---|---|
| UI | SwiftUI + UIKit interop where needed |
| Video engine | [AetherEngine](https://github.com/superuser404notfound/AetherEngine): FFmpeg demux, AVPlayer + VideoToolbox for HEVC / H.264 / HW-AV1, dav1d + libavcodec for AV1 / VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 software fallback; live TV ingested directly from HLS upstreams with engine-side DVR |
| Display | `AVPlayer` + `AVPlayerLayer` for the native path; `AVSampleBufferDisplayLayer` + `AVSampleBufferRenderSynchronizer` for the software path |
| Audio | `AVPlayer` over local HLS-fMP4 for the native path (Atmos as MAT 2.0, EAC3 5.1 bridge by default for Opus / TrueHD / MLP / DTS / DTS-HD MA / MP2 / MP3 so surround works on every modern soundbar via the bitstream tunnel; optional lossless FLAC bridge for AVRs that accept multichannel LPCM over HDMI); `AVSampleBufferAudioRenderer` for the software path |
| Networking | `URLSession` against the Jellyfin REST API |
| Persistence | Keychain for credentials, no telemetry storage |
| Media server | [Jellyfin](https://jellyfin.org) |

For the full pipeline detail (HDR routing, Atmos passthrough, A/V sync, channel-layout tagging), see the [AetherEngine README](https://github.com/superuser404notfound/AetherEngine#readme).

## Requirements

| | Min |
| --- | --- |
| Apple TV | 4K (any generation) |
| tvOS | 26.0 |
| Jellyfin server | 10.9+ recommended |
| Seerr (optional) | 2.0+ |

A 1080p Apple TV HD will technically run the app, but Direct Play of 4K HDR content needs the 4K hardware.

## Building from source

```bash
git clone https://github.com/superuser404notfound/Sodalite.git
cd Sodalite
open Sodalite.xcodeproj
```

Pick the `Sodalite` scheme, an Apple TV destination, and run. AetherEngine is referenced as a remote Swift Package pinned by commit SHA in `Package.resolved`, so Xcode resolves and fetches it from GitHub automatically. No local clone is required to build Sodalite.

If you also want to work on the engine, clone it next to this repo and switch the package reference to your local copy in Xcode:

```
~/Dev/
├── Sodalite/
└── AetherEngine/
```

Xcode 26+ and Swift 6.0+ are required.

For engine-level debugging without an Apple TV in the loop, AetherEngine ships a standalone macOS CLI (`aetherctl probe / serve / validate <url>`). See [AetherEngine's CLI docs](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/cli.md) for usage.

## Roadmap

- [x] Public TestFlight beta
- [x] Music library
- [ ] App Store release
- [ ] iOS / iPadOS companion app
- [ ] In-app library-update banner via Jellyfin's WebSocket, surfaces a quiet notification when Sonarr / Radarr ingests new content while Sodalite is open. No backend service, no APNs, same self-hosted data flow as everything else
- [x] Live TV + DVR support

## Community

Everything happens in the open. No Discord, no closed garden.

- **[Discussions](https://github.com/superuser404notfound/Sodalite/discussions)**: Q&A, ideas, show-and-tell
- **[Issues](https://github.com/superuser404notfound/Sodalite/issues)**: bugs and concrete feature requests

If you're not sure which to use, start a Discussion. Bugs get moved to Issues. Both are public, indexed by search engines, and stay tied to the project, so the next person with the same question can find the answer.

## Support

Sodalite is free and stays that way. If it's useful to you and you'd like to say thanks, there's a [Ko-fi](https://ko-fi.com/superuser404). The app also has an in-app Tip Jar and a Supporter Pack (cosmetics only, no gating).

## Related

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine): the video engine powering Sodalite
- [Jellyfin](https://github.com/jellyfin/jellyfin): the free software media system
- [Seerr](https://github.com/Fallenbagel/jellyseerr): request management for Jellyfin

## Built with

Sodalite is vibe-coded, designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

[GPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause keeps App Store and TestFlight distribution legally clean while the GPL keeps the source open and forks copyleft.
