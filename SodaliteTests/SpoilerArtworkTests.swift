import Foundation
import Testing
@testable import Sodalite

/// Sodalite#66. Backdrop and Thumb are show-level art by definition, so the cards drop the spoiler
/// blur there. That is only safe while the URL chain under those two options cannot fall back to
/// the episode's own still, which is what these pin: an unblurred card must never end up showing
/// item artwork for a hidden episode.
@MainActor
struct SpoilerArtworkTests {
    /// Home only needs the library service to load rows; these tests never load.
    private final class UnusedLibraryService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        struct Unused: Error {}
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { throw Unused() }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            []
        }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    private func makeViewModel() -> HomeViewModel {
        HomeViewModel(
            libraryService: UnusedLibraryService(),
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "https://jf.test") }),
            userID: "u1",
            serverID: "s1"
        )
    }

    private func episode(
        seriesID: String? = "series1",
        ownPrimary: Bool = true,
        ownBackdrop: Bool = false,
        parentBackdrop: Bool = false,
        seriesPoster: Bool = false
    ) throws -> JellyfinItem {
        var json = #"{"Id":"ep1","Name":"N","Type":"Episode""#
        if let seriesID { json += #","SeriesId":"\#(seriesID)""# }
        if ownPrimary { json += #","ImageTags":{"Primary":"own"}"# }
        if ownBackdrop { json += #","BackdropImageTags":["ownbd"]"# }
        if parentBackdrop { json += #","ParentBackdropImageTags":["parentbd"]"# }
        if seriesPoster { json += #","SeriesPrimaryImageTag":"seriesposter""# }
        json += "}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    // MARK: - Backdrop

    @Test("a hidden episode takes the show backdrop, not its own")
    func backdropPrefersTheShow() throws {
        let item = try episode(ownBackdrop: true, parentBackdrop: true)
        let url = makeViewModel().imageURL(
            for: item, rowType: .continueWatching, cwImage: .backdrop, spoilerSafe: true
        )
        #expect(url?.absoluteString.contains("/Items/series1/Images/Backdrop") == true)
    }

    @Test("without a show backdrop it falls to the show poster, never the still")
    func backdropFallsToShowPoster() throws {
        let item = try episode(ownBackdrop: true, seriesPoster: true)
        let url = makeViewModel().imageURL(
            for: item, rowType: .continueWatching, cwImage: .backdrop, spoilerSafe: true
        )
        #expect(url?.absoluteString.contains("/Items/series1/Images/Primary") == true)
    }

    @Test("with no show art at all a hidden episode gets no image rather than its own")
    func backdropRefusesItemArtwork() throws {
        let item = try episode(ownBackdrop: true)
        let url = makeViewModel().imageURL(
            for: item, rowType: .continueWatching, cwImage: .backdrop, spoilerSafe: true
        )
        #expect(url == nil)
    }

    @Test("a visible episode keeps the old chain")
    func backdropUnchangedWhenNothingIsHidden() throws {
        let item = try episode(ownBackdrop: true)
        let url = makeViewModel().imageURL(
            for: item, rowType: .continueWatching, cwImage: .backdrop
        )
        #expect(url?.absoluteString.contains("/Items/ep1/Images/Backdrop") == true)
    }

    // MARK: - Thumb

    @Test("Thumb asks the show, and a series-less episode gets no thumb of its own")
    func thumbStaysOnTheShow() throws {
        let vm = makeViewModel()
        let withSeries = vm.imageURL(
            for: try episode(), rowType: .nextUp, cwImage: .thumb, spoilerSafe: true
        )
        #expect(withSeries?.absoluteString.contains("/Items/series1/Images/Thumb") == true)

        let orphan = vm.imageURL(
            for: try episode(seriesID: nil), rowType: .nextUp, cwImage: .thumb, spoilerSafe: true
        )
        #expect(orphan == nil)
    }

    @Test("the Thumb fallback stays on show art too")
    func thumbFallbackStaysOnTheShow() throws {
        let vm = makeViewModel()
        let safe = vm.fallbackImageURL(
            for: try episode(ownBackdrop: true, parentBackdrop: true),
            cwImage: .thumb,
            spoilerSafe: true
        )
        #expect(safe?.absoluteString.contains("/Items/series1/Images/Backdrop") == true)

        let visible = vm.fallbackImageURL(
            for: try episode(ownBackdrop: true, parentBackdrop: true), cwImage: .thumb
        )
        #expect(visible?.absoluteString.contains("/Items/ep1/Images/Backdrop") == true)
    }

    // MARK: - Still

    @Test("the episode image option still shows the still, which is what the blur is for")
    func stillIsUntouched() throws {
        let url = makeViewModel().imageURL(
            for: try episode(), rowType: .continueWatching, cwImage: .still, spoilerSafe: true
        )
        #expect(url?.absoluteString.contains("/Items/ep1/Images/Primary") == true)
    }

    // MARK: - Service chain

    @Test("show artwork is the parent backdrop, then the series poster, then nothing")
    func seriesArtworkChain() throws {
        let service = JellyfinImageService(baseURLProvider: { URL(string: "https://jf.test") })
        let both = try episode(ownBackdrop: true, parentBackdrop: true, seriesPoster: true)
        #expect(service.seriesArtworkURL(for: both)?.absoluteString
            .contains("/Items/series1/Images/Backdrop") == true)
        let posterOnly = try episode(ownBackdrop: true, seriesPoster: true)
        #expect(service.seriesArtworkURL(for: posterOnly)?.absoluteString
            .contains("/Items/series1/Images/Primary") == true)
        #expect(service.seriesArtworkURL(for: try episode(ownBackdrop: true)) == nil)
    }
}
