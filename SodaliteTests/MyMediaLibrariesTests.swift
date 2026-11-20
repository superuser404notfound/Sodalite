import Testing
import Foundation
@testable import Sodalite

/// My Media used to list video libraries only, so the two views a viewer names most often, Collections
/// and Playlists, were reachable from Home rows but had no shortcut of their own (Discord, 2026-08-28).
/// Both are views without a folder behind them, so admitting them is not just a wider filter: the
/// tile's grid query has to change shape, and that is what these tests hold in place.
struct MyMediaLibrariesTests {
    private func library(_ id: String, _ type: String?) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: type, imageTags: nil)
    }

    @Test func theTwoViewTypesAreAdmittedAlongsideTheVideoLibraries() {
        let all = [
            library("m1", "movies"),
            library("t1", "tvshows"),
            library("h1", "homevideos"),
            library("x1", "mixed"),
            library("c1", "boxsets"),
            library("p1", "playlists"),
        ]
        #expect(MyMediaLibraries.browsable(all).map(\.id) == ["m1", "t1", "h1", "x1", "c1", "p1"])
    }

    /// Music and books have no grid to open, and a view with no collectionType at all is not a
    /// destination either.
    @Test func viewsWithoutAGridStayOut() {
        let all = [library("a1", "music"), library("b1", "books"), library("u1", nil)]
        #expect(MyMediaLibraries.browsable(all).isEmpty)
    }

    /// Jellyfin's Playlists view decodes to a type of its own; without the case it fell through to
    /// `.unknown` and the tile would have queried movies and series.
    @Test func theCollectionTypesDecodeToTheirOwnLibraryType() {
        #expect(library("c1", "boxsets").libraryType == .boxsets)
        #expect(library("p1", "playlists").libraryType == .playlists)
    }

    @Test func eachViewAsksForItsOwnItemType() {
        #expect(MyMediaLibraries.itemTypes(for: .movies) == [.movie])
        #expect(MyMediaLibraries.itemTypes(for: .tvshows) == [.series])
        #expect(MyMediaLibraries.itemTypes(for: .boxsets) == [.boxSet])
        #expect(MyMediaLibraries.itemTypes(for: .playlists) == [.playlist])
        // A mixed library carries both kinds and has no type of its own to ask for. A home-video
        // library never asks by type, it browses by folder (FolderBrowseTests).
        #expect(MyMediaLibraries.itemTypes(for: .homevideos) == [.movie, .series])
        #expect(MyMediaLibraries.itemTypes(for: .unknown) == [.movie, .series])
    }

    /// The load-bearing half: a real library scopes its grid by parentID, the two views must not, or
    /// the grid comes back empty.
    @Test func onlyTheTwoViewsSkipTheParentScope() {
        #expect(MyMediaLibraries.isVirtualView(.boxsets))
        #expect(MyMediaLibraries.isVirtualView(.playlists))
        #expect(!MyMediaLibraries.isVirtualView(.movies))
        #expect(!MyMediaLibraries.isVirtualView(.tvshows))
        #expect(!MyMediaLibraries.isVirtualView(.homevideos))
        #expect(!MyMediaLibraries.isVirtualView(.unknown))
    }

    /// Only the playlists grid pays the client-side filter; every other grid would drop nothing and
    /// still walk its whole page (see CollectionPlaylistHomeRowTests for why the filter exists).
    @Test func onlyThePlaylistsGridDropsAudioPlaylists() {
        #expect(MyMediaLibraries.hidesAudioPlaylists(.playlists))
        #expect(!MyMediaLibraries.hidesAudioPlaylists(.boxsets))
        #expect(!MyMediaLibraries.hidesAudioPlaylists(.movies))
    }
}

/// Sodalite#240: one tile for every movie and one for every series, once a viewer has more than one
/// library of that kind, on one server or across combined ones.
struct MyMediaAggregateTilesTests {
    private func library(_ id: String, _ type: String?, server: String = "a") -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: type, imageTags: nil, serverID: server)
    }

    @Test func oneLibraryOfAKindGetsNoAllTile() {
        let tiles = MyMediaLibraries.tiles([library("m1", "movies"), library("t1", "tvshows")])
        #expect(tiles.map(\.id) == ["m1", "t1"])
    }

    @Test func twoMovieLibrariesOnTwoServersGetAllMoviesFirst() {
        let tiles = MyMediaLibraries.tiles([
            library("m1", "movies", server: "a"), library("m1", "movies", server: "b"), library("t1", "tvshows"),
        ])
        #expect(tiles.map(\.id) == [MyMediaLibraries.allMoviesID, "m1", "m1", "t1"])
        #expect(MyMediaLibraries.aggregateType(tiles[0]) == .movie)
        #expect(MyMediaLibraries.aggregateType(tiles[1]) == nil)
    }

    /// A mixed library holds both kinds, so it counts towards both tiles.
    @Test func aMixedLibraryCountsForBoth() {
        let tiles = MyMediaLibraries.tiles([library("x1", "mixed"), library("m1", "movies"), library("t1", "tvshows")])
        #expect(tiles.prefix(2).map(\.id) == [MyMediaLibraries.allMoviesID, MyMediaLibraries.allSeriesID])
    }

    /// Collections, playlists and music never make a viewer's movies span two places.
    @Test func otherViewsDoNotCount() {
        let tiles = MyMediaLibraries.tiles([library("m1", "movies"), library("c1", "boxsets"), library("a1", "music")])
        #expect(!tiles.contains(where: MyMediaLibraries.isAggregate))
    }

    /// The tile hangs off an id no server mints, so the layout can hide and move it like a library
    /// without ever matching a real one.
    @Test func theLayoutHidesAnAllTileLikeALibrary() {
        let libraries = [library("m1", "movies"), library("m2", "movies")]
        let tiles = MyMediaLibraries.tiles(libraries)
        let layout = LibraryLayout(entries: []).toggling(tiles[0], in: tiles, fallbackServerID: "a")
        #expect(layout.visible(tiles, fallbackServerID: "a").map(\.id) == ["m1", "m2"])
        #expect(!layout.isHidden(libraries[0], fallbackServerID: "a"))
    }

    @Test func theBannerNeverOffersAnAllTile() {
        let tiles = MyMediaLibraries.tiles([library("m1", "movies"), library("m2", "movies")])
        #expect(HomeHeroLibraries.eligible(tiles).map(\.id) == ["m1", "m2"])
    }
}
