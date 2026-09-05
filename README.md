<p align="center">
  <img src=".github/sodalite-logo.png" alt="Sodalite" width="180">
</p>

<h1 align="center">Sodalite</h1>

<p align="center">
  <b>Your Jellyfin library <i>and</i> Seerr, together on every Apple screen.</b><br>
  Native for Apple TV, iPhone and iPad. Instant playback, real HDR, real Dolby Atmos.<br>
  Browse what you own. Request what's missing. Tune into live TV.<br>
  On the couch, in your hand, wherever you are.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tvOS-26%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/iOS%20%7C%20iPadOS-26%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-GPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
  <img src="https://img.shields.io/badge/languages-26-blue">
  <img src="https://img.shields.io/badge/status-public%20beta-orange">
  <a href="https://discord.gg/P7NvpzNqnG"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white"></a>
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

> 🧪 **Public Beta is open.** One TestFlight link installs on **Apple TV, iPhone and iPad**: **https://testflight.apple.com/join/nWeQzmBX**
> See [BETA.md](BETA.md) for what to focus on and how to report bugs.

---

## One app, every Apple screen

Sodalite is a **single universal app**. The same library, the same Seerr request loop, the same custom video stack, whether you're on the Apple TV in the living room, an iPhone on the train, or an iPad in bed. Sign in once per server; the whole experience follows the device you pick up.

It brings **Jellyfin and Seerr together in the same UI**. Watch what's already on your server. Spot something on a trending row that isn't there yet? Request it from inside the app, and Seerr handles the rest. No switching to a phone browser, no pinging your homelab admin, no leaving the app you're already in.

## Screenshots

<table>
  <tr>
    <td width="50%"><a href=".github/media/screenshot-home.jpg"><img src=".github/media/screenshot-home.jpg" alt="Home: Continue Watching, Next Up and Favorites rows"></a></td>
    <td width="50%"><a href=".github/media/screenshot-tv.jpg"><img src=".github/media/screenshot-tv.jpg" alt="Live TV: On Now and Series rows in the overview tab"></a></td>
  </tr>
  <tr>
    <td align="center"><b>Home</b> (Apple TV)</td>
    <td align="center"><b>Live TV</b> (Apple TV)</td>
  </tr>
  <tr>
    <td width="50%"><a href=".github/media/screenshot-catalog.jpg"><img src=".github/media/screenshot-catalog.jpg" alt="Catalog: Seerr Discover with Trending and Upcoming Movies"></a></td>
    <td width="50%"><a href=".github/media/screenshot-music.jpg"><img src=".github/media/screenshot-music.jpg" alt="Music: album track list with play and shuffle"></a></td>
  </tr>
  <tr>
    <td align="center"><b>Catalog</b> (Apple TV)</td>
    <td align="center"><b>Music</b> (Apple TV)</td>
  </tr>
</table>

<table>
  <tr>
    <td width="19%"><a href=".github/media/ios-home.jpg"><img src=".github/media/ios-home.jpg" alt="iPhone: Home with Continue Watching in portrait"></a></td>
    <td width="19%"><a href=".github/media/ios-detail.jpg"><img src=".github/media/ios-detail.jpg" alt="iPhone: movie detail page"></a></td>
    <td width="31%"><a href=".github/media/ipad-home.jpg"><img src=".github/media/ipad-home.jpg" alt="iPad: Home with Continue Watching and Next Up"></a></td>
    <td width="31%"><a href=".github/media/ipad-catalog.jpg"><img src=".github/media/ipad-catalog.jpg" alt="iPad: Seerr Catalog with Discover rows"></a></td>
  </tr>
  <tr>
    <td align="center"><b>Home</b> (iPhone)</td>
    <td align="center"><b>Detail</b> (iPhone)</td>
    <td align="center"><b>Home</b> (iPad)</td>
    <td align="center"><b>Catalog</b> (iPad)</td>
  </tr>
</table>

## What runs where

Almost everything is identical across devices, it's one codebase. A handful of capabilities are platform-native by design:

| Capability | Apple TV | iPhone &amp; iPad |
|---|:---:|:---:|
| Full library, Direct Play, HDR, Dolby Atmos, all subtitle formats | ✓ | ✓ |
| Seerr browse &amp; request, single sign-on | ✓ | ✓ |
| Live TV &amp; DVR | ✓ | ✓ |
| Music library | ✓ | ✓ |
| Watch Stats, parental controls, 26 languages | ✓ | ✓ |
| Picture in Picture | ✓ | ✓ |
| AirPlay to another display | – | ✓ |
| Full-screen video out over a wired HDMI adapter | – | ✓ |
| Rotation lock &amp; portrait player | – | ✓ |
| Child lock in the player | – | ✓ |
| Separate profiles per Apple TV user | ✓ | – |
| Top Shelf &amp; Siri Remote focus UX | ✓ | – |

## Open source, end to end

Sodalite is open from end to end. Every byte that touches your server is in this repo, your credentials live in your device's Keychain and sync between your devices only through your private iCloud, end-to-end encrypted so not even Apple can read them (turn iCloud Sync off and they never leave the device), and there's no telemetry, no analytics, no third-party SDK phoning home.

Licensed under **GPL-3.0 with an Apple Store / DRM Exception**. Fork it, study it, build your own version, but no one can take it private. Modifications must stay open. The exception clause in the LICENSE keeps the App Store and TestFlight distribution paths legally clean. The video stack underneath ([AetherEngine](https://github.com/superuser404notfound/AetherEngine)) is **LGPL-3.0** with the same Apple Store exception, so the engine can be reused in other apps while engine-level improvements flow back to the community. Both are auditable, buildable from source, and free of any vendor lock-in. Self-host the server, self-build the client, the whole loop is yours.

## Built natively for Apple platforms

Sodalite is built natively from the ground up: SwiftUI on top, a custom video engine underneath, and the same HIG patterns Apple uses across its own apps, focus engine and Siri Remote gestures on tvOS, touch and rotation on iPhone and iPad. It plays the file directly from your server in almost every case, no transcoding required, and live channels stream straight from their source where possible.

The Seerr integration isn't a tacked-on link to a web view. It's a first-class part of the app, with its own browse rows, request flow, and status tracking right next to your library.

## Features

### 📚 Browse & discover
- **Server discovery**: finds Jellyfin on your network automatically, or add manually
- **Multiple servers**: keep several Jellyfin servers in the app and switch between them without logging out; pick or add one from above your profile list, manage the full list in Settings → Servers
- **Internal / external URLs**: give a server both a local address and a remote one; Sodalite probes each and automatically switches to whichever one actually answers, rather than guessing from network type, so it keeps working over a VPN. Editable per server on iPhone and iPad, for both Jellyfin and Seerr, with a badge showing the active route; Apple TV resolves once when a session starts.
- **Home**: Continue Watching, Next Up, Latest Movies and Latest Shows, plus a My Media row to jump straight into any library; every row can be toggled and reordered, and Continue Watching and Next Up can optionally merge into a single row. Run several movie or series libraries and each one can also get a Latest row of its own
- **Latest vs. released**: the Latest rows order by when a title reached your server, the same as Jellyfin's own. If you'd rather see what came out recently, Customize Home has two Recently Released rows that order movies and shows by release date instead, a show ranking by its newest aired episode rather than by the year it started
- **Library**: Movies, Series, Collections with poster grids, instant filtering and an All / Unwatched / Watched watch-status filter on every grid; sort any library or genre grid by title, release date, date added, rating or runtime in either direction, remembered per library and synced across your devices; a library grid follows your server's "Group movies into collections" setting, so a collection shows up as one tile, and you can override that per server in Settings → Customize Home
- **Series view**: season picker, episode list, "Up Next" highlighting
- **Collections and playlists**: a detail page that opens straight on its film list and plays through in order, starting from the first title you haven't finished; playlists also get their own Home row
- **Search**: across your whole server, results as you type; with Jellyseerr connected, actors and directors come back as people of their own, and opening one lands on their photo, biography and full filmography
- **Image caching & prefetching**: posters and backdrops load before you reach them
- **Delete from the app**: remove movies, series, or individual seasons from your library, with optional cleanup of matching Radarr / Sonarr entries when Jellyseerr is connected
- **Rich detail pages**: cast, ratings, where-to-watch and more-like-this on catalog titles; tagline, director, writer and studios on your own library. Similar titles come in two rows, what your server already has and, with Jellyseerr connected, what it would still have to fetch, so a suggestion is either one click from playing or one click from a request
- **Title logos & synopses**: detail screens float the title logo over the backdrop and show full episode synopses, both toggleable in Appearance settings
- **Full-bleed backdrops**: artwork shines through the whole detail page and dims as you scroll; titles without backdrop art get an ambient poster fill instead of a grey plate
- **Watched tracking**: mark movies, episodes, seasons or whole series as watched or unwatched, with progress badges across Home and detail screens. A part-watched card carries an inset capsule with the time left beside it, so a row tells you which title is a twelve minute job and which is an hour, and a finished one wears the watched check alone
- **Poster badges**: optional pills in the corner of every card showing resolution (4K, 1080p), dynamic range (Dolby Vision, HDR10+, HDR10, HLG) and spatial audio (Atmos, DTS:X). Off by default in Appearance settings, because the picture and sound pills need a stream lookup per row; the resolution comes along for free with the card itself
- **Favorites**: heart a movie, series, collection or a single episode; favorited episodes get their own Home row, alongside the Favorites row for everything else
- **Cast & filmography**: open any cast member to see their photo, biography and full filmography, then jump straight to a title in your library or request it from the catalog. The page leads with what you already own, movies, series and the single episodes they guest in, and an episode opens its series at exactly that episode. Without Jellyseerr the page keeps that library half instead of going blank

### 🎬 Watch
- **Direct Play** for almost every codec on your server: H.264, HEVC, HEVC Main10, AV1, VP9, VP8, MPEG-4 Part 2 (XVID / DIVX), MPEG-2, VC-1, and the legacy Microsoft tail that old rips carry (MS-MPEG4 v1 / v2 / v3, the DivX 3.x era, plus WMV1 / WMV2 / WMV3). Containers: MKV, MP4, MOV, AVI, MPEG-TS, M2TS, VOB, 3GP, WebM, OGG, FLV. Server-side transcoding stays reserved for fringe codecs (Theora, RealVideo) and for `.wmv` files themselves, whose ASF container the engine does not demux.
- **HDR10, HDR10+, Dolby Vision, HLG**: auto-detected, sent through with full color metadata. HDR10+ streams forward per-frame ST 2094-40 dynamic metadata so HDR10+ displays apply the source's tone-mapping curves; Dolby Vision streams switch DV-capable Apple TVs into Dolby Vision mode for Profile 5, 8.1 and 8.4 (Profile 7 is converted to single-layer 8.1 on device so it engages DV too): Profile 5 signals via a bare `dvh1` track tag, while 8.1 and 8.4 carry `dvh1` in `SUPPLEMENTAL-CODECS` on an `hvc1` base. On Apple TV the display switches to the matching HDR mode automatically (Match Content); on iPhone and iPad the built-in HDR display renders it directly. On a display that has no Dolby Vision of its own, an experimental Playback setting can hand the per-frame Dolby Vision data to the Apple TV instead of the panel, so a Profile 8.1 source is composed on device rather than sent as its static HDR10 layer.
- **Dolby Atmos** via EAC3+JOC, wrapped as Dolby MAT 2.0 so an AVR's Atmos light actually comes on over an Apple TV; on iPhone and iPad it plays through spatialized audio where the device supports it
- **Multichannel surround**: 5.1, 7.1 with correct channel layout
- **Resume** from where you left off, on any device
- **Restart from the beginning**: a dedicated button on movies, series and episodes to play from the start instead of resuming
- **Pick your source**: when a title has more than one version on your server (different rips, resolutions or editions), a picker lets you choose which one to play before playback starts, on both movies and episodes
- **Shuffle a series**: a shuffle button on series detail queues random episodes across every season
- **Trailers**: play a title's local trailer straight from your server with a dedicated button on the detail page
- **Intro skip**: auto-detected from your Jellyfin server, optional one-tap skip
- **Recap skip**: the same one-tap skip for a "previously on" recap when your server marks one, with its own auto-skip setting (off by default)
- **Next episode**: auto-play with countdown, or just an overlay; configurable. Turn the countdown off and the card stays without a timer, so credits and post-credit scenes play out before the next episode starts. Dismissing the card only clears it off the picture, the switch still happens at the end of the episode
- **Subtitles, all formats, client-side**: text codecs (SubRip, ASS, SSA, WebVTT, mov_text) decoded inline in AetherEngine as packets flow through the demuxer, no server extraction lag on first hit. Bitmap subtitles (PGS, HDMV PGS, DVB, DVD) rendered as native images at the right position on the frame, no more relying on the server having Tesseract installed for Blu-ray rips. Sidecar `.srt` / `.ass` / `.vtt` files parsed by FFmpeg as well. In-band CEA-608 closed captions (the `eia_608` caption track some streams and rips carry) are decoded on-device too and appear in the subtitle menu like any other track. DVB Teletext subtitle pages from broadcast and live TV are decoded on-device as well, with their original colors preserved. Styled ASS / SSA rendering keeps the original fonts, colors and positioning, for both embedded and external sidecar tracks (toggle between styled and plain text in Playback settings). Track switching mid-playback, with auto-resolution against your preferred audio / subtitle language.
- **Forced subtitles with subtitles off**: forced captions (signs, translated foreign dialogue) still show while your subtitles are off, like a disc player would. A dedicated forced track matching the audio language is used when the release has one; otherwise the forced-flagged cues inside the full PGS / DVD track are rendered on their own. Fully automatic, the subtitle menu keeps showing "None".
- **Subtitles on skip back**: the "wait, what did they say?" case. Skipping backward switches subtitles on at the landing point and off again once playback has caught up with where you jumped from, the way tvOS does it for its own player. Consecutive presses extend the one window, picking a track yourself ends it, and the temporary pick is never remembered as your choice. Works on Live TV inside the timeshift window as well. On by default, switchable in Settings → Playback → Subtitles on Skip Back
- **Subtitle search & download**: when your server is missing the right track, search and download subtitles from inside the player. Files that match by content hash get a badge so you know they line up, and ones you added can be removed with a long press.
- **Dual subtitles**: show a second simultaneous subtitle track above the first, for example the original language plus a translation. Pick a secondary track from the Secondary section at the top of the subtitle menu (text tracks only).
- **Audio track switcher**: pick the language or surround mix you want, mid-playback
- **Remembered track selection**: the audio and subtitle track you pick in the player comes back next time you play that title. Movies keep their own choice, episodes share one per series, so a subtitle picked on episode 1 carries through the show. Turning subtitles off is remembered too, and a remembered pick beats both your preferred-language setting and the foreign-audio automatic for that one title (forced captions still show, as above). Since track numbering shifts between the episodes of a series, the pick is matched by language, by role (forced, SDH, commentary) and by format rather than by track number, falling back to your normal settings when an episode has no equivalent instead of picking something in the wrong language. Stored per profile, carried across devices by iCloud sync, and switchable in Settings → Playback → Remember track selection
- **Scrub preview**: thumbnails of the exact frame as you scrub, floating above the playhead, generated on-device by AetherEngine straight from the video so they land on the precise frame and work even when your server has no trickplay images prepared. An optional setting lets you prefer your server's pre-generated trickplay images instead (decode-free, lighter on older devices), falling back to on-device when the server has none
- **Custom player UI**: a hand-built transport bar and info panel on top of our own video engine, matching the gestures and feel of Apple's own player without using the system player
- **Click to pause**: on Apple TV a click pauses or resumes straight away, the way the system player does, instead of first waking the transport. Up or Down still opens the transport without touching playback, and a remote's dedicated play/pause key toggles in a single press. It matters most for TV remotes that drive the box over HDMI-CEC, where Select is often the only key that gets through
- **Instant skip**: left or right seeks on the press, rather than putting the target time on the bar and waiting for a click to confirm it, and letting go of a held key commits the spool the same way. Presses in quick succession add up into a single seek, so tapping right three times moves once by three intervals instead of reloading three times
- **Swipe to scrub**: dragging across the Siri Remote's touch surface moves the playhead, and Settings → Playback → Swipe to Scrub turns that off for anyone who drives the box by clicking the ring, so a thumb resting on the pad cannot shift the timeline. Left and right keep seeking either way
- **Play from the start**: a From Start control in the player jumps a movie or episode back to the beginning without leaving playback, for when you resumed by mistake or just want to watch it again. Your resume point follows immediately, so closing the player right after keeps the restart
- **Picture in Picture**: shrink playback into a floating window and keep browsing, or leave the app entirely. On Apple TV start it from a dedicated transport-bar button (video and Live TV); on iPhone and iPad it also engages automatically when you swipe home. On iPhone and iPad it also works for software-decoded titles (AV1 without hardware decode, VP9), with the window's own play/pause/skip controls driving the engine directly; tvOS cannot offer that yet because its AVKit never engages picture in picture for sample-buffer sources. Text subtitles render inside the PiP window on the native path and survive seeking in both directions
- **Now Playing skip**: the 10-second forward and backward buttons in the system Now Playing controls (Control Center on iPhone and iPad, the Now Playing panel on Apple TV) route through to the engine via `MPRemoteCommandCenter`, App Store compliant, no private API
- **Network buffer depth**: pick how far ahead playback reads in Settings → Playback. The default follows the engine (about 40 seconds ahead); one-minute, five-minute and Maximum (about 10 minutes) steps ride out slow mounts and busy servers, and Unlimited keeps pre-buffering the title for as long as the device's free space safely allows (up to a quarter of it), so a flaky connection can drop out for minutes without the picture stalling.
- **Stats for Nerds overlay**: optional info panel during playback, on video and on live TV alike. The static sections come from the engine, so they describe the stream that actually arrived: video codec / resolution / framerate / bitrate / range / decoder, audio codec / channels / bitrate / decoder, subtitle codec, play method and the container the demuxer opened. Filename and file size come from Jellyfin, which is the only side that knows them. A live channel shows its name, number, tuner id and the route the tune took (direct, transcode, tuner file or static) where a file would be. Live section refreshes at 1 Hz with instant + average bitrate from the demuxer, forward buffer + cached MB, network throughput, dropped frames (native AVPlayer) or observed FPS (software AV1), plus a colour-coded A/V sync gap. A second toggle adds an Engine Diagnostics deep-dive (producer restarts, RSS, demuxer / muxer / audio-bridge bytes, server traffic) for troubleshooting. Enable in Settings → Playback → Advanced.

### 📱 On iPhone & iPad
- **AirPlay**: send any title to an AirPlay display, with HDR and surround metadata preserved
- **Wired HDMI out**: plug in a USB-C to HDMI adapter and playback fills the connected screen instead of showing the mirrored phone window, with HDR / Dolby Vision and match-frame-rate passed through. With subtitles switched on the app takes the screen over to draw them there, video included, since the system's own external playback keeps subtitles on the phone
- **Rotation lock**: a one-tap toggle in the player pins landscape (or lets it follow the device), with a lock indicator so you always know which mode you're in
- **Child lock**: one tap in the player disables every touch, so a child can watch without accidentally skipping, pausing, or leaving; release it by pressing and holding the on-screen pill for a moment
- **Format badge**: the top bar surfaces the live format (Dolby Vision, HDR10+, Atmos and friends) so you can confirm at a glance what's actually playing
- **Portrait-safe chrome**: player controls stay correctly placed in portrait and landscape, no clipped buttons behind the notch or home indicator
- **Touch-native throughout**: swipe to scrub, tap to play/pause, drag the grids, the whole app is built for touch as a first-class input, not a ported remote UI
- **Hardware keyboard**: with a keyboard attached to an iPad, Space plays and pauses, a tap on the left or right arrow jumps your configured skip interval, and holding one spools through the timeline with the same preview the remote gets, committing where you let go

### 📺 Live TV & DVR
- **Overview tab**: Live TV opens on a category-based overview of what's on right now, with rows mirroring the native Jellyfin guide, before you drop into the full grid
- **Programme guide**: full EPG grid with a sticky channel column, wall-clock time ruler, live now-line and current-program highlighting; open a program for info, watch and record actions
- **Channel favorites**: star channels in the guide, favorites sort to the top
- **Timeshift**: pause live TV, scrub back up to 10 minutes with on-device frame previews, snap back with Return to Live
- **Recordings & timers**: record a program or a whole series from the guide, manage scheduled timers, and play finished or still-recording shows
- **Direct from the source**: most channels play straight from their upstream, starting in seconds with no server transcoding, with automatic fallback through Jellyfin when a source needs it
- **Same engine as movies**: H.264 / HEVC channels ride the native pipeline, MPEG-2 / VC-1 and friends decode in software, and dead sources fail fast with a clear message instead of an endless spinner
- **Broadcast picture**: interlaced channels (1080i, 576i and the like) are hardware-deinterlaced on the fly for a clean progressive image
- **Live subtitles**: channels that carry a subtitle track offer it in the player like any other title, including the WebVTT renditions the public broadcasters ship alongside their HLS streams, drawn on the frame with your own font, size and position settings. Your preferred subtitle language applies to channels too, and because broadcasters routinely ship their subtitle stream without stating a language, a channel whose only track is unlabelled counts as being in the language of the broadcast instead of being skipped. A channel whose audio carries no language is still left alone rather than treated as foreign. The Teletext page used for decoding broadcast transport streams is set in Settings, Playback

### 🎵 Listen
- **Music library**: browse your Jellyfin music by album and play it back through the same engine, with a native Now Playing screen, cover art, scrubbing and background playback
- **Ambient Now Playing (Apple TV)**: after five seconds of quiet the queue and the transport step aside and leave the artwork and title centered on screen, the way Apple Music's Now Playing behaves. Any press or swipe brings them straight back

### 📨 Request what's missing
- **Seerr integration**: browse trending and popular media right inside the app
- **One-tap requests** for movies and full series
- **Collections**: a movie that belongs to a series of films (Despicable Me, John Wick, Toy Story) links straight to its collection, showing every part with its availability and requesting all the ones you're missing in one go
- **Track status**: see what's been approved, declined, or is already downloading
- **Honest availability**: cross-checks your Jellyfin library so a title (or single season) deleted in Radarr / Sonarr shows as gone, not a stale "available", and stays re-requestable
- **Single sign-on**: log in once, Sodalite handles your Seerr session
- **Admin view**: with Jellyseerr admin permissions, approve, decline, edit, or delete any user's request right from the All Requests tab

### 🌍 Personal
- **iCloud Sync**: servers, logins and settings sync automatically across every device signed into the same iCloud account, end-to-end encrypted so only your devices can read the secrets (tokens, passwords, Seerr sessions, your Guardian PIN); on by default, manage it from Settings → iCloud Sync with a live status, a manual "push this device's settings" action, a "load settings from iCloud" pull for when you don't want to wait for the next automatic fetch, and the option to delete your iCloud data entirely
- **Multiple profiles**: keep more than one login remembered per server and switch between them without re-entering a password; the launch picker opens on your active profile first, and an optional setting brings the picker back automatically after the app has spent a while in the background (Settings → Profile)
- **Parental controls**: set a Guardian PIN, then choose per profile whether it opens freely, needs the PIN to open, or needs the PIN to leave; a locked device returns to the profile picker on a cold start, gated actions ask for the PIN first, the parental settings themselves always do, and recovery goes through the Jellyfin password of a PIN-protected profile
- **Tab visibility**: Settings → Tabs chooses which tabs the navigation bar shows. Switching Catalog off also drops the catalog results from Search and from person pages, so the Jellyseerr side is gone rather than one level deeper, which keeps the app to what is actually on the server for family users. Home and Settings always stay, Live TV and Music still depend on the server offering them, and the screen sits behind the Guardian PIN when one is set
- **Watch Stats**: a Settings screen with your viewing totals, movies and episodes watched, completion rate, estimated hours, top genres, most-rewatched and recently-watched titles, all aggregated client-side from standard Jellyfin data
- **Diagnostic Log**: Settings → Diagnostic Log shows the last 300 diagnostic lines from the current app session, so a bug report can carry the actual error instead of a description of it; kept in memory only, nothing is written to disk or uploaded, and it can be copied on iPhone or screenshotted on Apple TV
- **26 languages**: German, English, Spanish, French, Italian, Japanese, Korean, Norwegian, Dutch, Polish, Portuguese (BR + PT), Russian, Swedish, Simplified + Traditional Chinese, Turkish, Ukrainian, Czech, Slovak, Croatian, Finnish, Greek, Hungarian, Romanian, Danish
- **Dark, minimal design** that puts the artwork first, on the big screen and in your hand
- **Appearance options**: choose artwork style, card size, title logos and poster badges, plus three free accent colors and Graphite Glass or OLED Black backgrounds; the optional Supporter Pack adds curated Pastel, Bold, Electric and Cinematic palettes plus animated Aurora and Noir backgrounds
- **Liquid Glass** UI accents on tvOS 26 and iOS 26
- **Input-native everywhere**: Siri Remote touch scrubbing, click for play/pause and swipe gestures on Apple TV; touch scrubbing and gestures on iPhone and iPad

## Built on

Sodalite is a thin native shell over a custom video stack: Apple's frameworks plus a Swift package that handles the formats Apple's own player can't on its own. The same stack runs on tvOS, iOS and iPadOS.

| Component | Technology |
|---|---|
| UI | SwiftUI + UIKit interop where needed, one universal target for Apple TV, iPhone and iPad |
| Video engine | [AetherEngine](https://github.com/superuser404notfound/AetherEngine): FFmpeg demux, AVPlayer + VideoToolbox for HEVC / H.264 / HW-AV1, dav1d + libavcodec for AV1 / VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 / MS-MPEG4 / WMV software fallback; live TV ingested directly from HLS upstreams with engine-side DVR |
| Display | `AVPlayer` + `AVPlayerLayer` for the native path; `AVSampleBufferDisplayLayer` + `AVSampleBufferRenderSynchronizer` for the software path |
| Audio | `AVPlayer` over local HLS-fMP4 for the native path (Atmos as MAT 2.0, EAC3 5.1 bridge by default for Opus / TrueHD / MLP / DTS / DTS-HD MA / MP2 / MP3 so surround works on every modern soundbar via the bitstream tunnel; optional lossless FLAC bridge for AVRs that accept multichannel LPCM over HDMI); `AVSampleBufferAudioRenderer` for the software path |
| Networking | `URLSession` against the Jellyfin REST API |
| Persistence | Keychain for credentials, no telemetry storage |
| Media server | [Jellyfin](https://jellyfin.org) |

For the full pipeline detail (HDR routing, Atmos passthrough, A/V sync, channel-layout tagging), see the [AetherEngine README](https://github.com/superuser404notfound/AetherEngine#readme).

## Requirements

| Device | Min |
| --- | --- |
| Apple TV | 4K (any generation), tvOS 26 |
| iPhone | iOS 26 |
| iPad | iPadOS 26 |
| Jellyfin server | 10.9+ recommended |
| Seerr (optional) | 2.0+ |

A 1080p Apple TV HD will technically run the app, but Direct Play of 4K HDR content needs the 4K hardware. On iPhone and iPad the built-in display renders HDR directly, no external panel required.

## Building from source

```bash
git clone https://github.com/superuser404notfound/Sodalite.git
cd Sodalite
open Sodalite.xcodeproj
```

Pick the `Sodalite-tvOS` scheme for Apple TV, or `Sodalite-iOS` for iPhone and iPad, choose a matching destination, and run. AetherEngine is referenced as a remote Swift Package pinned by commit SHA in `project.yml`, so Xcode resolves and fetches it from GitHub automatically. No local clone is required to build Sodalite.

If you also want to work on the engine, clone it next to this repo and switch the package reference to your local copy in Xcode:

```
~/Dev/
├── Sodalite/
└── AetherEngine/
```

Xcode 26+ and Swift 6.0+ are required. The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); the generated `Sodalite.xcodeproj` is committed, so a plain checkout builds without extra tooling. If you change targets or build settings, edit `project.yml` and regenerate with `Scripts/generate-project.sh`.

For engine-level debugging without a device in the loop, AetherEngine ships a standalone macOS CLI (`aetherctl probe / serve / validate <url>`). See [AetherEngine's CLI docs](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/cli.md) for usage.

The App Store marketing screenshots are generated from raw device shots by a small Node + Playwright pipeline in `Tools/appstore-shots/` (real screenshots on a designed background, localized headlines in 26 languages). See its [README](Tools/appstore-shots/README.md).

## Roadmap

What is being built next lives in [ROADMAP.md](ROADMAP.md). No dates, no version promises, just
the short list of what is in flight.

## Community

Everything that matters happens in the open.

- **[Discord](https://discord.gg/P7NvpzNqnG)**: chat, quick questions, release announcements
- **[Discussions](https://github.com/superuser404notfound/Sodalite/discussions)**: Q&A, ideas, show-and-tell
- **[Issues](https://github.com/superuser404notfound/Sodalite/issues)**: bugs and concrete feature requests

Discord is the fast lane, GitHub is the record. Anything that should still be findable next year, a bug, a feature request, a decision, ends up in an Issue or a Discussion: those are public, indexed by search engines, and stay tied to the project, so the next person with the same question finds the answer. If you're not sure which to use, start a Discussion. Bugs get moved to Issues.

## Support

Sodalite is free and stays that way. If it's useful to you and you'd like to say thanks, there's a [Ko-fi](https://ko-fi.com/superuser404). The app also has an in-app Tip Jar and an optional Supporter Pack with cosmetic extras; every functional feature remains free.

## Related

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine): the video engine powering Sodalite
- [Jellyfin](https://github.com/jellyfin/jellyfin): the free software media system
- [Seerr](https://github.com/Fallenbagel/jellyseerr): request management for Jellyfin

## Built with

Sodalite is vibe-coded, designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

[GPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause keeps App Store and TestFlight distribution legally clean while the GPL keeps the source open and forks copyleft.
