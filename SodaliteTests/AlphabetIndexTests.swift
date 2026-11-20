import Foundation
import Testing
@testable import Sodalite

struct AlphabetIndexTests {
    @Test func railIsHashThenAToZ() {
        #expect(AlphabetIndex.letters.count == 27)
        #expect(AlphabetIndex.letters.first == "#")
        #expect(AlphabetIndex.letters[1] == "A")
        #expect(AlphabetIndex.letters.last == "Z")
        #expect(AlphabetIndex.railLetters(descending: true).first == "Z")
        #expect(AlphabetIndex.railLetters(descending: true).last == "#")
    }

    @Test(arguments: [
        ("the matrix", "T"), ("Ärger im Paradies", "A"), ("élite", "E"), ("2001", "#"),
        ("Брат", "#"), ("", "#"), ("  zodiac", "Z"), ("!Women Art Revolution", "#"),
    ])
    func letterForSortName(name: String, expected: String) {
        #expect(AlphabetIndex.letter(for: name) == expected)
    }

    private var base: ItemQuery {
        ItemQuery(parentID: "lib", includeItemTypes: [.movie], sortBy: "SortName", sortOrder: "Ascending",
                  limit: 200, fields: JellyfinEndpoint.homeRowFields)
    }

    @Test func ascendingCountsTitlesBeforeTheLetter() throws {
        var filtered = base
        filtered.filters = ["IsUnplayed"]
        filtered.startIndex = 400
        let query = try #require(AlphabetIndex.countQuery(for: "P", base: filtered, descending: false))
        #expect(query.nameLessThan == "p")
        #expect(query.nameStartsWithOrGreater == nil)
        #expect(query.limit == 0)
        #expect(query.startIndex == nil)
        #expect(query.fields == "")
        #expect(query.filters == ["IsUnplayed"])
        #expect(query.parentID == "lib")
    }

    @Test func ascendingHashIsSlotZeroWithoutRequest() {
        #expect(AlphabetIndex.countQuery(for: "#", base: base, descending: false).map { _ in true } == nil)
    }

    @Test func descendingCountsTitlesFromTheNextLetter() throws {
        let p = try #require(AlphabetIndex.countQuery(for: "P", base: base, descending: true))
        #expect(p.nameStartsWithOrGreater == "q")
        #expect(p.nameLessThan == nil)
        let z = try #require(AlphabetIndex.countQuery(for: "Z", base: base, descending: true))
        #expect(z.nameStartsWithOrGreater == "{")
        let hash = try #require(AlphabetIndex.countQuery(for: "#", base: base, descending: true))
        #expect(hash.nameStartsWithOrGreater == "a")
    }

    @Test func railShowsForEveryTitleSortedGrid() {
        #expect(AlphabetIndex.showsRail(sortKey: .title, total: 1))
        #expect(!AlphabetIndex.showsRail(sortKey: .title, total: 0))
        #expect(!AlphabetIndex.showsRail(sortKey: .dateAdded, total: 500))
    }

    @Test func firstPositionWalksLoadedTitles() {
        let names = ["2 Fast", "Alien", "Batman", "Dune", "Élan", "Zodiac"]
        #expect(AlphabetIndex.firstPosition(of: "#", in: names, descending: false) == 0)
        #expect(AlphabetIndex.firstPosition(of: "B", in: names, descending: false) == 2)
        // No C: lands on the next letter that has titles.
        #expect(AlphabetIndex.firstPosition(of: "C", in: names, descending: false) == 3)
        #expect(AlphabetIndex.firstPosition(of: "E", in: names, descending: false) == 4)
        // Past the end of what is loaded.
        #expect(AlphabetIndex.firstPosition(of: "Q", in: Array(names.prefix(4)), descending: false) == nil)

        let reversed = Array(names.reversed())
        #expect(AlphabetIndex.firstPosition(of: "Z", in: reversed, descending: true) == 0)
        #expect(AlphabetIndex.firstPosition(of: "C", in: reversed, descending: true) == 3)
        #expect(AlphabetIndex.firstPosition(of: "#", in: reversed, descending: true) == 5)
    }
}
