import Testing
import Foundation
@testable import Sodalite

/// A cast row identifies its cards by person id, and a repeated id makes SwiftUI's ForEach "give
/// undefined results": measured on tvOS as a card slot that holds its space and draws nothing, on
/// other update paths as a row that keeps the previous item's cast. Servers hand out a credit per
/// job, so the same person arrives more than once (Big Buck Bunny: Sacha Goedegebure directed and
/// wrote it). These pin the merge that gives the row one entry per person.
struct CastMemberMergeTests {

    private func member(_ id: String, _ name: String, _ role: String?, image: String? = nil) -> CastMember {
        CastMember(
            id: id,
            name: name,
            role: role,
            imageURL: image.flatMap(URL.init(string:)),
            personID: nil,
            jellyfinPersonID: id
        )
    }

    /// The reported page: two credits for one person, one for another.
    @Test func twoCreditsForOnePersonBecomeOneCard() {
        let merged = [
            member("p-sacha", "Sacha Goedegebure", "Director"),
            member("p-sacha", "Sacha Goedegebure", "Screenplay"),
            member("p-ton", "Ton Roosendaal", "Producer")
        ].mergingDuplicatePeople()

        #expect(merged.map(\.id) == ["p-sacha", "p-ton"])
        #expect(merged[0].role == "Director, Screenplay")
        #expect(merged[1].role == "Producer")
    }

    /// Whatever else the merge does, the ids it hands the row have to be unique. That is the
    /// invariant the blank slot came from.
    @Test func idsAreUnique() {
        let merged = [
            member("a", "A", "One"), member("b", "B", nil), member("a", "A", "Two"), member("a", "A", "Three")
        ].mergingDuplicatePeople()
        #expect(Set(merged.map(\.id)).count == merged.count)
        #expect(merged[0].role == "One, Two, Three")
    }

    /// A row of distinct people is not a case, so it must come back exactly as it went in, order
    /// included: the cast order is the server's statement about billing.
    @Test func distinctPeoplePassThroughUnchanged() {
        let cast = [member("a", "A", "Actor"), member("b", "B", "Director"), member("c", "C", nil)]
        #expect(cast.mergingDuplicatePeople() == cast)
    }

    /// The first credit holds the place, so a merge cannot reorder the row.
    @Test func theMergedEntryKeepsTheFirstPosition() {
        let merged = [
            member("p-sacha", "Sacha Goedegebure", "Director"),
            member("p-ton", "Ton Roosendaal", "Producer"),
            member("p-sacha", "Sacha Goedegebure", "Screenplay")
        ].mergingDuplicatePeople()
        #expect(merged.map(\.id) == ["p-sacha", "p-ton"])
        #expect(merged[0].role == "Director, Screenplay")
    }

    /// Jellyfin leaves Role empty for plenty of crew credits, and an empty half must not show up as
    /// a stray separator.
    @Test func anEmptyCreditDoesNotBecomeASeparator() {
        let merged = [
            member("p", "P", nil), member("p", "P", "Producer"), member("p", "P", "   ")
        ].mergingDuplicatePeople()
        #expect(merged.count == 1)
        #expect(merged[0].role == "Producer")
    }

    /// Nothing to say about a person stays nothing, rather than an empty line under the name.
    @Test func aPersonWithNoCreditsAtAllKeepsNoRole() {
        let merged = [member("p", "P", nil), member("p", "P", nil)].mergingDuplicatePeople()
        #expect(merged.count == 1)
        #expect(merged[0].role == nil)
    }

    /// The same job twice (TMDB writes "Writer" for both the story and the screenplay often enough)
    /// is one job, not a stutter.
    @Test func theSameCreditTwiceIsNotRepeated() {
        let merged = [member("p", "P", "Writer"), member("p", "P", "writer")].mergingDuplicatePeople()
        #expect(merged[0].role == "Writer")
    }

    /// Jellyfin attaches the portrait to the credit, not to the person, so the picture can hang on
    /// the second entry. Dropping it would turn a face into initials.
    @Test func aPortraitOnTheLaterCreditIsKept() {
        let merged = [
            member("p", "P", "Director"),
            member("p", "P", "Screenplay", image: "https://example.invalid/p.jpg")
        ].mergingDuplicatePeople()
        #expect(merged.count == 1)
        #expect(merged[0].imageURL?.absoluteString == "https://example.invalid/p.jpg")
    }
}
