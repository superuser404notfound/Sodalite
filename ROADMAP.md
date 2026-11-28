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

The search field itself is settled. On Apple TV the tab runs on the system search (the one the App
Store and the Apple TV app use), with dictation, the system keyboard and system focus handling, so
the browse screen goes into the empty space under its keyboard.

### Emby, Plex and Silo servers ([#51](https://github.com/superuser404notfound/Sodalite/issues/51))

Sodalite gets a second kind of server next to Jellyfin: Emby first, then Plex, and Silo with its
own features rather than through the Jellyfin side door.

Emby is closest. Adding an Emby server already works today, because discovery and the system
endpoints still look the way Jellyfin's do. It falls over one step later, at the profile login:
Sodalite signs in the Jellyfin way, and Emby moved its authentication somewhere else after the
fork.

That one call is the small part. The moment a second backend exists, every screen that touches a
library, plus playback reporting and the device profile, has two servers to be correct against,
and there is no Emby box here to test any of it on. That is why it sits here and not in Next: it
is worth doing properly, and doing it properly is a good deal bigger than the request that fails
today.

Plex is larger again, because its API shares nothing with Jellyfin's. Silo already works today
through its Jellyfin compatibility layer, except subtitle search, which that layer does not answer
yet. A native Silo path would be about the things the compatibility layer leaves out.

## Considering

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
