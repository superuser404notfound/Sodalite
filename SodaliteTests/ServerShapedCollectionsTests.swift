import Testing
import Foundation
@testable import Sodalite

/// A server that curates its collections (several collection libraries, one per shelf, with
/// landscape or square covers and mixed film/show members) reported through plain Jellyfin fields:
/// `CollectionType: "boxsets"` per library and `PrimaryImageAspectRatio` per cover (Discord,
/// 2026-11-07). Sodalite poured every box set into one poster row and cropped the covers.
@MainActor
struct ServerShapedCollectionsTests {

    private func item(_ id: String, type: String = "BoxSet", ratio: Double? = nil, primary: Bool = true) -> JellyfinItem {
        var fields = ["\"Id\":\"\(id)\"", "\"Name\":\"\(id)\"", "\"Type\":\"\(type)\""]
        if let ratio { fields.append("\"PrimaryImageAspectRatio\":\(ratio)") }
        if primary { fields.append("\"ImageTags\":{\"Primary\":\"t\"}") }
        return try! JSONDecoder().decode(JellyfinItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func library(_ id: String, _ type: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: type, imageTags: nil)
    }

    // MARK: Card shape

    @Test func ratioMapsToCardShape() {
        #expect(ArtworkShape.style(forAspectRatio: 16.0 / 9.0) == .landscape)
        #expect(ArtworkShape.style(forAspectRatio: 1) == .square)
        #expect(ArtworkShape.style(forAspectRatio: 2.0 / 3.0) == .poster)
        #expect(ArtworkShape.style(forAspectRatio: nil) == nil)
        #expect(ArtworkShape.style(forAspectRatio: 0) == nil)
    }

    @Test func posterRowFollowsTheMajorityOfItsCovers() {
        let wide = (0..<3).map { item("w\($0)", ratio: 1.78) }
        #expect(ArtworkShape.style(for: wide + [item("p", ratio: 0.67)], default: .poster) == .landscape)
        #expect(ArtworkShape.style(for: [item("a", ratio: 1), item("b", ratio: 1)], default: .poster) == .square)
        #expect(ArtworkShape.style(for: [item("a", ratio: 1.78), item("b", ratio: 0.67)], default: .poster) == .poster)
        #expect(ArtworkShape.style(for: [], default: .poster) == .poster)
    }

    /// An episode drawn with its series poster has a 16:9 ratio of its own that says nothing about
    /// the card, and a row that is landscape by design never turns into posters.
    @Test func onlyOwnCoversVoteAndDesignedRowsKeepTheirStyle() {
        let borrowed = (0..<3).map { item("e\($0)", type: "Episode", ratio: 1.78, primary: false) }
        #expect(ArtworkShape.style(for: borrowed, default: .poster) == .poster)
        #expect(ArtworkShape.style(for: [item("p", ratio: 0.67)], default: .landscape) == .landscape)
    }

    @Test func homeAndGridAskForTheRatio() {
        #expect(JellyfinEndpoint.homeRowFields.split(separator: ",").contains("PrimaryImageAspectRatio"))
        #expect(JellyfinEndpoint.detailFields.split(separator: ",").contains("PrimaryImageAspectRatio"))
    }

    // MARK: One shelf per collection library

    @Test func severalCollectionLibrariesSplitIntoShelvesOnAFreshInstall() {
        let libs = [library("c1", "boxsets"), library("c2", "boxsets"), library("m", "movies")]
        let result = HomeRowConfig.reconciled(stored: [], libraries: libs, isFreshInstall: true)
            .sorted { $0.sortOrder < $1.sortOrder }
        let shelves = result.filter { $0.type == .libraryLatest && $0.collectionType == "boxsets" }
        #expect(shelves.map(\.libraryID) == ["c1", "c2"])
        #expect(shelves.allSatisfy { $0.isEnabled })
        #expect(result.first { $0.type == .collections }?.isEnabled == false)
    }

    /// A saved layout gets the split once, when the shelves first appear and Collections is on.
    @Test func savedLayoutSplitsOnceWhileCollectionsIsOn() {
        let libs = [library("c1", "boxsets"), library("c2", "boxsets")]
        let stored = HomeRowConfig.defaultConfig()
        let first = HomeRowConfig.reconciled(stored: stored, libraries: libs)
        #expect(first.filter { $0.collectionType == "boxsets" }.allSatisfy { $0.isEnabled })
        #expect(first.first { $0.type == .collections }?.isEnabled == false)

        // The user turns a shelf off: the next pass must not switch it back on.
        var edited = first
        if let i = edited.firstIndex(where: { $0.libraryID == "c2" }) { edited[i].isEnabled = false }
        let second = HomeRowConfig.reconciled(stored: edited, libraries: libs)
        #expect(second.first { $0.libraryID == "c2" }?.isEnabled == false)
    }

    @Test func savedLayoutWithCollectionsOffStaysOff() {
        var stored = HomeRowConfig.defaultConfig()
        if let i = stored.firstIndex(where: { $0.type == .collections }) { stored[i].isEnabled = false }
        let result = HomeRowConfig.reconciled(stored: stored, libraries: [library("c1", "boxsets"), library("c2", "boxsets")])
        #expect(result.filter { $0.collectionType == "boxsets" }.allSatisfy { !$0.isEnabled })
    }

    /// Jellyfin's own single Collections view splits nothing: the aggregated row stays as it was.
    @Test func singleCollectionsViewKeepsTheAggregatedRow() {
        let result = HomeRowConfig.reconciled(stored: [], libraries: [library("c", "boxsets")], isFreshInstall: true)
        #expect(!result.contains { $0.type == .libraryLatest })
        #expect(result.first { $0.type == .collections }?.isEnabled == true)
    }

    @Test func shelfQueryKeepsServerOrderAndScope() {
        let query = HomeViewModel.collectionShelfQuery(libraryID: "c1")
        #expect(query.parentID == "c1")
        #expect(query.sortBy == nil)
        #expect(query.includeItemTypes == nil)
        #expect(query.recursive)
    }

    @Test func myMediaScopesCollectionTilesOnlyAmongSeveral() {
        let a = library("c1", "boxsets"), b = library("c2", "boxsets")
        #expect(MyMediaLibraries.scopesCollections(a, among: [a, b]))
        #expect(!MyMediaLibraries.scopesCollections(a, among: [a]))
        let scoped = MyMediaLibraries.gridQuery(for: a, grouping: .system, scopesCollections: true)
        #expect(scoped.parentID == "c1")
        #expect(MyMediaLibraries.gridQuery(for: a, grouping: .system).parentID == nil)
    }

    // MARK: Collection page

    @Test func longNestedOrWideCollectionsUseAGrid() {
        let franchise = (0..<8).map { item("m\($0)", type: "Movie", ratio: 0.67) }
        #expect(!CollectionMembers.usesGrid(franchise))
        #expect(CollectionMembers.usesGrid((0..<13).map { item("m\($0)", type: "Movie", ratio: 0.67) }))
        #expect(CollectionMembers.usesGrid([item("sub")] + franchise))
        #expect(CollectionMembers.usesGrid((0..<3).map { item("w\($0)", type: "Movie", ratio: 1.78) }))
    }

    @Test func filterAppearsOnlyForMixedCollections() {
        let movies = [item("m1", type: "Movie"), item("m2", type: "Movie")]
        let mixed = movies + [item("s1", type: "Series")]
        #expect(!CollectionMembers.offersFilter(movies))
        #expect(CollectionMembers.offersFilter(mixed))
        #expect(CollectionMembers.visible(mixed, filter: .shows).map(\.id) == ["s1"])
        #expect(CollectionMembers.visible(mixed, filter: .movies).map(\.id) == ["m1", "m2"])
        #expect(CollectionMembers.visible(movies, filter: .shows).count == 2)
    }

    @Test func pagingStopsOnAShortPageOrTheCap() {
        #expect(!CollectionMembers.isLastPage(received: 50, loaded: 50))
        #expect(CollectionMembers.isLastPage(received: 49, loaded: 99))
        #expect(CollectionMembers.isLastPage(received: 50, loaded: CollectionMembers.memberCap))
    }
}
