import Foundation
import Testing
@testable import Sodalite

@Suite("Top Shelf artwork choice")
struct TopShelfArtworkTests {

    private static let episode = TopShelfArtwork.Available(
        isEpisode: true,
        itemID: "ep",
        seriesID: "series",
        primary: "still-tag",
        thumb: nil,
        backdrop: nil,
        parentBackdrop: "series-backdrop-tag",
        parentThumb: "series-thumb-tag",
        parentThumbID: nil
    )

    private static let movie = TopShelfArtwork.Available(
        isEpisode: false,
        itemID: "movie",
        seriesID: nil,
        primary: "poster-tag",
        thumb: "movie-thumb-tag",
        backdrop: "movie-backdrop-tag",
        parentBackdrop: nil,
        parentThumb: nil,
        parentThumbID: nil
    )

    /// The app writes its own enum's raw value into the shared container, so the two lists have to
    /// stay the same list. A rename on either side would silently land every install on `.still`.
    @Test("the app's picker and the shelf's choices are the same three values")
    func rawValuesAgree() {
        #expect(AppearancePreferences.ContinueWatchingImage.allCases.map(\.rawValue)
            == TopShelfArtwork.Choice.allCases.map(\.rawValue))
    }

    @Test("still is what the shelf drew before the setting existed")
    func stillPrefersTheEpisodeFrame() {
        #expect(TopShelfArtwork.source(for: .still, Self.episode)
            == TopShelfArtwork.Source(itemID: "ep", kind: .primary, tag: "still-tag"))
        #expect(TopShelfArtwork.source(for: .still, Self.movie)
            == TopShelfArtwork.Source(itemID: "movie", kind: .backdrop, tag: "movie-backdrop-tag"))
    }

    @Test("an episode without a still falls back to its own Thumb, then the show's backdrop")
    func stillDegrades() {
        var art = Self.episode
        art.primary = nil
        art.thumb = "episode-thumb-tag"
        #expect(TopShelfArtwork.source(for: .still, art)
            == TopShelfArtwork.Source(itemID: "ep", kind: .thumb, tag: "episode-thumb-tag"))

        art.thumb = nil
        #expect(TopShelfArtwork.source(for: .still, art)
            == TopShelfArtwork.Source(itemID: "series", kind: .backdrop, tag: "series-backdrop-tag"))
    }

    /// The reason the setting exists: an episode still is capped at the server's image-extraction
    /// width, the show's backdrop is not.
    @Test("backdrop takes the show's backdrop for an episode")
    func backdropPrefersTheShow() {
        #expect(TopShelfArtwork.source(for: .backdrop, Self.episode)
            == TopShelfArtwork.Source(itemID: "series", kind: .backdrop, tag: "series-backdrop-tag"))
        #expect(TopShelfArtwork.source(for: .backdrop, Self.movie)
            == TopShelfArtwork.Source(itemID: "movie", kind: .backdrop, tag: "movie-backdrop-tag"))
    }

    @Test("backdrop falls back to the still rather than dropping the cell")
    func backdropDegradesToStill() {
        var art = Self.episode
        art.parentBackdrop = nil
        #expect(TopShelfArtwork.source(for: .backdrop, art)
            == TopShelfArtwork.Source(itemID: "ep", kind: .primary, tag: "still-tag"))
    }

    @Test("thumb takes the show's Thumb for an episode, its own for a movie")
    func thumbPrefersTheShow() {
        #expect(TopShelfArtwork.source(for: .thumb, Self.episode)
            == TopShelfArtwork.Source(itemID: "series", kind: .thumb, tag: "series-thumb-tag"))
        #expect(TopShelfArtwork.source(for: .thumb, Self.movie)
            == TopShelfArtwork.Source(itemID: "movie", kind: .thumb, tag: "movie-thumb-tag"))
    }

    /// `ParentThumbItemId` can name a season rather than the series, and it is the id the tag
    /// belongs to.
    @Test("thumb follows the item the parent tag belongs to")
    func thumbUsesTheParentThumbOwner() {
        var art = Self.episode
        art.parentThumbID = "season"
        #expect(TopShelfArtwork.source(for: .thumb, art)
            == TopShelfArtwork.Source(itemID: "season", kind: .thumb, tag: "series-thumb-tag"))
    }

    /// A server that does not fill `ParentThumbImageTag` leaves the Thumb chain empty; the cell
    /// then draws the backdrop, and the shelf never asks for a picture that would 404 (one failed
    /// candidate costs the whole shelf its accent bars).
    @Test("thumb degrades to backdrop, then to the still")
    func thumbDegrades() {
        var art = Self.episode
        art.parentThumb = nil
        #expect(TopShelfArtwork.source(for: .thumb, art)
            == TopShelfArtwork.Source(itemID: "series", kind: .backdrop, tag: "series-backdrop-tag"))

        art.parentBackdrop = nil
        #expect(TopShelfArtwork.source(for: .thumb, art)
            == TopShelfArtwork.Source(itemID: "ep", kind: .primary, tag: "still-tag"))
    }

    @Test("an item with no artwork at all resolves to nothing")
    func noArtworkAtAll() {
        let bare = TopShelfArtwork.Available(isEpisode: true, itemID: "ep")
        for choice in TopShelfArtwork.Choice.allCases {
            #expect(TopShelfArtwork.source(for: choice, bare) == nil)
        }
    }
}
