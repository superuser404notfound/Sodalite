# Roadmap

What is being built next, and nothing else. There are no dates on this page. Sodalite is built by
one person in his spare time, and a date here would be a guess wearing the costume of a promise.

The buckets, once they have content:

- **Next**: being designed or built right now
- **Later**: decided, not scheduled
- **Considering**: still an open question, feedback welcome
- **Not planned**: decided against, with the reason

Only buckets that hold something appear below. Everything else lives in
[Issues](https://github.com/superuser404notfound/Sodalite/issues) and
[Discussions](https://github.com/superuser404notfound/Sodalite/discussions). A request that is
not on this page has not been rejected, it has simply not been picked up yet.

## Later

### Something to browse before you type ([#107](https://github.com/superuser404notfound/Sodalite/issues/107))

Search is the only tab that shows nothing at all until you start typing, which on a remote is the
most expensive thing it could ask for. It gets the two things that belong on an empty search
screen: your recent searches, and a grid of genre tiles you can walk into. The genres are the same
tiles Home already shows, pointing at the same grids Home has already loaded, so picking one lands
on content instead of a spinner.

Behind that sits an open question. Sodalite draws its own search field today, and tvOS has a real
system search screen (the one the App Store and the Apple TV app use) that brings dictation, the
system keyboard and system focus handling with it. Switching to it was measured as too slow once
before, with a related but different API. It gets measured again on an actual Apple TV, and if
opening the tab is still slower than it is today, the field stays as it is and the browse screen
ships anyway.

### Fill the screen on a wide film ([#118](https://github.com/superuser404notfound/Sodalite/issues/118))

Picture Size gets a real zoom: pick the film's ratio (1.85, 2.00, 2.35, 2.40, 4:3) and the picture
scales up until the image fills the screen, with the sides running off the edges. Same thing the
Zoom button on a TV does, on the display layer, so nothing is decoded or encoded a second time.

It is there because today's Fill does nothing at all on most wide films. Fill only finds something
to crop when the video file itself is a different shape than the screen, and a wide film usually
arrives as a 16:9 file with the black bars painted into the picture, so there is nothing to crop.
Working the ratio out on its own can come later, with the menu kept as the override. And when the
picture already fills the screen, the setting is greyed out instead of pretending to do something.

Two things you give up on purpose: a 2.39:1 film loses about a quarter of its width, and any
subtitles burned into the bar area go with it.

### Emby servers ([#51](https://github.com/superuser404notfound/Sodalite/issues/51))

Adding an Emby server already works today, because discovery and the system endpoints still look
the way Jellyfin's do. It falls over one step later, at the profile login: Sodalite signs in the
Jellyfin way, and Emby moved its authentication somewhere else after the fork.

That one call is the small part. The moment a second backend exists, every screen that touches a
library, plus playback reporting and the device profile, has two servers to be correct against,
and there is no Emby box here to test any of it on. That is why it sits here and not in Next: it
is worth doing properly, and doing it properly is a good deal bigger than the request that fails
today.

Plex has been weighed next to it and would be larger again. Neither goes in front of 1.0.

## Considering

### A Mac app ([#181](https://github.com/superuser404notfound/Sodalite/issues/181))

Sodalite on the Mac, built from the same sources as the iPhone and iPad app (Mac Catalyst), with
your servers, profiles and settings coming along through iCloud the way they already do between an
Apple TV and an iPhone.

The app code is the smaller part. The video engine underneath already compiles for the Mac, but
the FFmpeg libraries it ships with do not exist in a Mac Catalyst build yet, and adding them makes
the download bigger for every platform, Apple TV included. On top of that, several things the
engine does on iOS mean something else on a desktop: an iPhone app leaving the screen is about to
be suspended, a Mac window losing focus is not, and playback must not tear itself down every time
you switch to another window. Each of those has to be decided on purpose rather than inherited.

Whether that is worth it next to everything in Later is the open question. Thoughts welcome in the
issue, especially how you would watch on a Mac: a window next to your work, or full screen.

### A Home that keeps up on its own ([#117](https://github.com/superuser404notfound/Sodalite/issues/117))

Jellyfin can say what changed instead of being asked. The server keeps a socket open and announces
it, and Home could follow that live: a row moves while you are looking at it, and how old the shelf
is stops being a question at all.

Today Home refetches at moments Sodalite can recognise: coming back to the tab, the app coming back
to the foreground, and anything you changed yourself. That covers what it can see, and it will
always be a guess about what it cannot. Start a film on a laptop in another room and it appears in
Continue Watching the next time one of those moments comes round, rather than the moment it
happens.

What is not settled is whether it earns its keep. It means a second live connection held open on a
device that spends most of its life asleep, and reconnect handling for every way that connection
can quietly die, to replace something that already refreshes when you come back. That is why it
sits here rather than in Later. Thoughts welcome in the issue.
