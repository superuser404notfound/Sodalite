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
