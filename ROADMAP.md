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

## Next

### Offline downloads ([#81](https://github.com/superuser404notfound/Sodalite/issues/81))

Download movies and episodes to the device and play them back without a server connection:
commuting, flights, hotel wifi that only pretends to work. iPhone and iPad first, because that is
where a file on disk earns its storage.

Targeted at 1.1, the first release after 1.0.

## Later

### One home across every server ([#85](https://github.com/superuser404notfound/Sodalite/issues/85))

An opt-in mode that keeps more than one Jellyfin session alive at the same time and merges the
Home tab across them: one Continue Watching row in true chronological order, one My Media grid
holding every library from every box, and the Live TV tab present when any connected server has
a tuner. Search stays scoped to one server you pick, because merging relevance rankings from two
servers invents an order neither of them meant.

Off by default. With the switch off, Sodalite behaves exactly as it does today.

### Jump to a letter ([#86](https://github.com/superuser404notfound/Sodalite/issues/86))

A slim A to Z rail down the right edge of a library grid: move onto it, slide to P, and the grid
lands on the first title starting with P instead of coasting past ninety-five posters. Plex has
this on Apple TV and almost no other Jellyfin client does. It only means anything while a library
is sorted by title, so it appears with that sort and stays out of the way otherwise.

### Pick a quality ([#87](https://github.com/superuser404notfound/Sodalite/issues/87))

Choose what leaves the server: the original file, or a smaller stream when the connection cannot
carry it. Once as a default in the playback settings, and once in the player itself for the times
the default is wrong. When downloads land, the same choice decides what gets stored, because a
phone has less room than a NAS.

The original file stays the default. A lower rung means the server re-encodes, which is exactly
what Sodalite avoids by default, so it is a trade you make on purpose rather than a slider that
quietly costs nothing.

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

Picture Size offers Original and Fill, and Fill only finds something to crop when the video file
itself is a different shape than the screen. Most wide films arrive as a 16:9 file with the black
bars painted into the picture, so there is nothing to crop and the option does nothing at all.

It gets a real zoom instead: pick the film's ratio (1.85, 2.00, 2.35, 2.40, 4:3) and the picture
scales up until the image fills the screen, with the sides running off the edges. Same thing the
Zoom button on a TV does, on the display layer, so nothing is decoded or encoded a second time.
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
