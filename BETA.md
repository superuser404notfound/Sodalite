# Sodalite Beta, for testers

Thanks for testing Sodalite. This page tells you how to get the build, what to look at, and how to report what you find.

> **Just want to use Sodalite?** It is on the [App Store](https://apps.apple.com/app/sodalite/id6764418563), free. The TestFlight beta carries the *next* version before it ships, so it can be rougher, and installing it replaces the App Store version on that device. If TestFlight shows no build to install, there is no pre-release in testing right now: use the App Store version until the next one is up.

## What Sodalite is

A native media player for your own Jellyfin server, one universal app for **Apple TV, iPhone and iPad**, with built-in [Seerr](https://github.com/Fallenbagel/jellyseerr) browse + request flow. Direct Play, live TV with DVR, real HDR10 / Dolby Vision, real Dolby Atmos. On iPhone and iPad you also get AirPlay and Picture in Picture. Open source ([GPL-3.0 with App Store Exception](LICENSE)), no telemetry.

For the long pitch see the [README](README.md).

## What you need

- **An Apple TV 4K (tvOS 26+), an iPhone (iOS 26+), or an iPad (iPadOS 26+)**. The same app runs on all three, test on as many as you have
- A **Jellyfin server** you can reach from the device (10.9+ recommended)
- *Optional:* a **Seerr / Jellyseerr** instance (2.0+) if you want to test the request flow
- An **Apple ID** signed in on the device (no invite required, this is a public beta)

## Install the build

1. On any device signed in with your Apple ID, open the public TestFlight link: **https://testflight.apple.com/join/nWeQzmBX**
2. Tap **Accept**, then **Install** on whichever devices you want to test. iPhone, iPad and Apple TV all install from the same link
3. On Apple TV, first install the **TestFlight** app from the App Store if it isn't already there, sign in with the same Apple ID, then install **Sodalite** from the list
4. Open it from the home screen

If it tells you "this beta has expired", revisit the join link above to grab the current build. TestFlight builds expire after 90 days.

## What to test

The high-value areas, what we most want feedback on:

### Setup & connection
- Server discovery (auto + manual). Auto-discovery needs the server reachable by LAN broadcast (bare-metal, or Docker with host networking). A bridge-networked Docker server won't be found, that's expected, use manual entry
- Login with username + password, with and without Quick Connect
- Reconnecting after the app comes back from background
- Parental controls: set a Guardian PIN, lock a profile, confirm gated actions ask for it, and try recovery via your Jellyfin password

### Browsing
- Home customization (Continue Watching, Next Up, Latest, custom rows, the combined Continue Watching + Next Up toggle)
- The All / Unwatched / Watched filter on library grids
- Series detail view, switch seasons, scroll long episode lists
- Watch Stats (Settings, Watch Stats): do the totals, completion rate and top genres look right for your library?
- Search, both your library and the Seerr catalog (when Seerr is connected)

### Music (if your server has a music library)
- Browse albums, play a few tracks, check the Now Playing screen and background playback

### Live TV (if your server has it)
- The guide: scroll a big channel list, both directions, does focus stay in your time column?
- Zap through channels: how fast do they start, does anything stall or stay black?
- Pause live TV, scrub back, return to live
- Record a program and a series from the guide, check the Recordings tab, play a finished recording
- A channel that is known-broken on your server: does Sodalite say so quickly instead of spinning?

### Playback
- A title with more than one version on your server: does the version picker appear, and does your pick play?
- A series shuffle: does the shuffle button queue random episodes across seasons?
- A local trailer from the detail page
- A regular SDR movie
- An HDR10 / Dolby Vision movie if you have one. Does the TV switch into HDR mode? Does the picture look right?
- An EAC3+JOC (Atmos) stream if you have one. Does your AVR's Atmos light come on?
- Track switching mid-playback (audio language, subtitle language)
- Subtitle search: when a track is missing, search and download one from inside the player
- Dual subtitles: pick a secondary track from the Secondary section at the top of the subtitle menu and confirm two lines render (try an SRT and an ASS track). Switching the secondary track and turning it off should work, and seeking should keep both lines in sync
- An ASS / SSA subtitle track with heavy styling (anime fansubs are ideal): do fonts, colors and positions look right? Try the styled / plain toggle in Playback settings
- Resume from where you stopped, on multiple devices
- Network Buffer (Settings > Playback > Streaming): on a slow WebDAV / rclone-backed server, raise the level and watch the lighter buffered-ahead band on the scrub bar grow as the on-disk buffer fills. It applies to direct play; a server-transcoded title shows no band
- Auto-play next episode for series
- The 10-second skip buttons in the system Now Playing controls (Control Center on iPhone / iPad, the Now Playing panel on Apple TV)

### On iPhone & iPad
- Rotate the device during playback: does the video follow, and does the rotation-lock toggle pin it where you want?
- Picture in Picture: start PiP, leave the app, come back. Do text subtitles show in the PiP window and stay in sync when you seek both directions?
- AirPlay: send a title to an AirPlay display, does it start, and do HDR / surround survive?
- Wired HDMI out: plug in a USB-C to HDMI adapter. Does playback fill the connected screen, does HDR / Dolby Vision pass through, and do subtitles show on the external screen and stay in sync when you seek? With subtitles on the app takes the screen over (the phone keeps its own picture then): does HDR / Dolby Vision still come through in that state? A software-decoded title (an MPEG-2 or VC-1 file, for example) should show only on the connected screen too, with the controls left on the device; what happens to its picture when you lock the device?
- Portrait and landscape: are the player controls fully visible, nothing clipped behind the notch or home indicator?
- iPad multitasking (Split View / Slide Over) if you use it

### Seerr integration
- Browse trending / popular
- Request a movie or series
- Status display for what you've requested

### Edge cases
- Slow Wi-Fi
- Multiple Apple TVs on the same Jellyfin account
- Going to background mid-playback (Siri Remote home button) and coming back

## How to report a bug

Open an issue on GitHub: **<https://github.com/superuser404notfound/Sodalite/issues/new/choose>**

Please include:

1. **What you did**: exact steps
2. **What you expected**
3. **What actually happened**
4. **Build version**: Settings, scroll to the bottom, e.g. `0.12.0 (1)`
5. **Device & OS version**: which device, and its tvOS / iOS / iPadOS version (System, About on Apple TV; Settings, General, About on iPhone / iPad)
6. **Jellyfin server version** if relevant
7. **A screenshot** if it's a visual bug. On iPhone / iPad use the usual shortcut (side + volume-up, or top + home on older models). On Apple TV press `TV` + `Play/Pause` on the Siri Remote and the screenshot lands on your Mac via Photos.
8. *Optional:* TestFlight Feedback (long-press in the TestFlight app) attaches a screenshot + system info automatically, also fine

Bugs already known live in the [open issues](https://github.com/superuser404notfound/Sodalite/issues). Search before filing a duplicate.

## What you should NOT expect from a beta

- **Crashes are possible.** Your device won't be damaged, but you may have to relaunch.
- **Some features may be incomplete.** For example, HDR display switching depends on TV model and the Match Content setting. On a wired external display, subtitles are drawn by the app, which takes the external screen over to do it (video included, and the phone keeps its own picture); the system's own external playback leaves subtitles on the phone, so this is the only way they reach the screen. It happens only while a subtitle is switched on, and if the takeover does not produce a picture the app hands the screen straight back, so playback continues without the external subtitles. Whether HDR / Dolby Vision mode matching survives the takeover is still being verified. AirPlay keeps its native subtitle path.
- **TestFlight builds expire after 90 days.** You'll get a new invite when a fresh build lands.
- **Your watch progress is stored on your Jellyfin server**, not in the app. If you reinstall you keep all your progress.

## Privacy reminder

Sodalite does not collect, transmit, or share any usage data. Everything stays between your Apple TV and the servers you point it at. Full details: <https://sodalite.superuser404.de/privacy>.

## Thanks

If something feels off, tell us. If something feels good, also tell us. Both kinds of feedback help.
