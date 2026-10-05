import Testing
import Foundation
@testable import Sodalite

@MainActor
struct MyRequestsDiffTests {
    static let movieRequestJSON = """
    {"id":7,"status":2,"createdAt":"2026-10-05T09:12:33.000Z","updatedAt":"2026-10-05T09:20:00.000Z",
     "type":"movie","is4k":false,
     "media":{"id":3,"tmdbId":550,"mediaType":"movie","status":5,"jellyfinMediaId":"abc123"},
     "requestedBy":{"id":4,"displayName":"kid"}}
    """

    @Test func requestMediaDecodesJellyfinID() throws {
        let request = try JSONDecoder().decode(SeerrRequest.self, from: Data(Self.movieRequestJSON.utf8))
        #expect(request.media?.jellyfinMediaId == "abc123")
    }

    @Test func myRequestsSortByModificationReachesQuery() throws {
        let items = SeerrEndpoint.myRequests(userID: 4, take: 50, skip: 0, sort: .modified).queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "sort", value: "modified")))
        #expect(items.contains(URLQueryItem(name: "requestedBy", value: "4")))
    }

    private func obs(
        id: Int = 1, by requester: Int? = 4, created: Date? = Date(timeIntervalSince1970: 2_000),
        type: SeerrMediaType = .movie, status: SeerrRequestStatus = .pendingApproval,
        media: SeerrMediaStatus? = .unknown, requested: [Int] = [], available: Set<Int> = []
    ) -> MyRequestObservation {
        MyRequestObservation(
            requestID: id, requesterID: requester, createdAt: created, mediaType: type, tmdbID: 100 + id,
            jellyfinItemID: nil, requestStatus: status, mediaStatus: media,
            requestedSeasons: requested, availableSeasons: available
        )
    }
    private let me = 4
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 5_000)

    private func baseline(_ observations: [MyRequestObservation]) -> MyRequestsSnapshot {
        MyRequestsDiff.apply(snapshot: nil, observations: observations, selfID: me, now: t0).snapshot
    }

    @Test func firstRunIsSilent() {
        let result = MyRequestsDiff.apply(snapshot: nil, observations: [obs(status: .approved, media: .available)], selfID: me, now: t0)
        #expect(result.events.isEmpty)
        #expect(result.snapshot.baselineDate == t0)
        #expect(result.snapshot.entries[1] != nil)
    }

    @Test func pendingToApprovedEmitsApproved() {
        let snap = baseline([obs()])
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [obs(status: .approved, media: .processing)], selfID: me, now: t1)
        #expect(result.events.map(\.kind) == [.approved])
    }

    @Test func declinedAndFailedEmitOnce() {
        let snap = baseline([obs(id: 1), obs(id: 2, status: .approved)])
        let first = MyRequestsDiff.apply(snapshot: snap, observations: [obs(id: 1, status: .declined), obs(id: 2, status: .failed)], selfID: me, now: t1)
        #expect(Set(first.events.map(\.kind)) == [.declined, .failed])
        let second = MyRequestsDiff.apply(snapshot: first.snapshot, observations: [obs(id: 1, status: .declined), obs(id: 2, status: .failed)], selfID: me, now: t1)
        #expect(second.events.isEmpty)
    }

    @Test func movieAvailableSupersedesApproved() {
        let snap = baseline([obs()])
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [obs(status: .completed, media: .available)], selfID: me, now: t1)
        #expect(result.events.map(\.kind) == [.available])
    }

    @Test func otherUsersRequestsAreIgnored() {
        let snap = baseline([])
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [obs(id: 9, by: 77, status: .approved, media: .available)], selfID: me, now: t1)
        #expect(result.events.isEmpty)
        #expect(result.snapshot.entries[9] == nil)
    }

    @Test func onlyOwnRequestedSeasonsCount() {
        // Show partially available because ANOTHER user's season 2 landed; my request is season 1.
        let mine = obs(type: .tv, status: .approved, media: .processing, requested: [1])
        let snap = baseline([mine])
        let stillWaiting = obs(type: .tv, status: .approved, media: .partiallyAvailable, requested: [1], available: [])
        #expect(MyRequestsDiff.apply(snapshot: snap, observations: [stillWaiting], selfID: me, now: t1).events.isEmpty)
        let landed = obs(type: .tv, status: .approved, media: .partiallyAvailable, requested: [1], available: [1])
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [landed], selfID: me, now: t1)
        #expect(result.events.map(\.kind) == [.available])
        #expect(result.events.first?.seasons == [1])
    }

    @Test func availableSeasonsOutsideRequestAreIgnored() {
        let snap = baseline([obs(type: .tv, status: .approved, media: .processing, requested: [1])])
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [obs(type: .tv, status: .approved, media: .partiallyAvailable, requested: [1], available: [2])], selfID: me, now: t1)
        #expect(result.events.isEmpty)
    }

    @Test func newRequestAfterBaselineCountsAsPending() {
        let snap = baseline([])
        let late = obs(id: 5, created: Date(timeIntervalSince1970: 3_000), status: .completed, media: .available)
        #expect(MyRequestsDiff.apply(snapshot: snap, observations: [late], selfID: me, now: t1).events.map(\.kind) == [.available])
    }

    @Test func unknownRequestFromBeforeBaselineIsRecordedSilently() {
        let snap = baseline([])
        let old = obs(id: 5, created: Date(timeIntervalSince1970: 500), status: .declined)
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [old], selfID: me, now: t1)
        #expect(result.events.isEmpty)
        #expect(result.snapshot.entries[5] != nil)
    }

    @Test func requestsOutsideTheFetchedWindowKeepTheirEntry() {
        // Users with more than one page: an old request drops out of the window, then an approval
        // bumps its modification date back in. It must still be compared against what we saw.
        let snap = baseline([obs(id: 1, created: Date(timeIntervalSince1970: 500)), obs(id: 2)])
        let windowed = MyRequestsDiff.apply(snapshot: snap, observations: [obs(id: 2)], selfID: me, now: t1)
        #expect(windowed.snapshot.entries.keys.sorted() == [1, 2])
        #expect(windowed.snapshot.baselineDate == t0)
        let back = MyRequestsDiff.apply(snapshot: windowed.snapshot, observations: [obs(id: 1, created: Date(timeIntervalSince1970: 500), status: .approved)], selfID: me, now: t1)
        #expect(back.events.map(\.kind) == [.approved])
    }

    @Test func snapshotIsCappedKeepingNewestRequests() {
        var snap = baseline([])
        snap.entries = Dictionary(uniqueKeysWithValues: (1...600).map { ($0, MyRequestsSnapshot.Entry(requestStatus: 2, mediaStatus: 3, availableSeasons: [])) })
        let result = MyRequestsDiff.apply(snapshot: snap, observations: [obs(id: 1)], selfID: me, now: t1)
        #expect(result.snapshot.entries.count == MyRequestsDiff.snapshotLimit)
        #expect(result.snapshot.entries[1] != nil)
        #expect(result.snapshot.entries[600] != nil)
        #expect(result.snapshot.entries[2] == nil)
    }

    @Test func ownFreshAutoApprovedRequestIsNotAnnouncedAsApproved() {
        // An admin (or auto-approve user) submits on this device: the request is already approved
        // the first time we see it, and nobody needs to be told about their own click.
        let snap = baseline([])
        let fresh = obs(id: 6, created: Date(timeIntervalSince1970: 3_000), status: .approved, media: .processing)
        #expect(MyRequestsDiff.apply(snapshot: snap, observations: [fresh], selfID: me, now: t1).events.isEmpty)
    }

    @Test func observationFromWirePayloadParsesDateAndSeasons() throws {
        let request = try JSONDecoder().decode(SeerrRequest.self, from: Data(Self.movieRequestJSON.utf8))
        let observation = MyRequestObservation(request: request, availableSeasons: [])
        #expect(observation.requesterID == 4)
        #expect(observation.jellyfinItemID == "abc123")
        #expect(observation.createdAt == Date(timeIntervalSince1970: 1_791_191_553))
    }

    @Test func mergeUnionsSeasonsOfSameRequestAndKind() {
        let a = MyRequestEvent(requestID: 1, kind: .available, mediaType: .tv, tmdbID: 1, seasons: [1], jellyfinItemID: nil, title: nil, posterPath: nil, date: t0)
        let b = MyRequestEvent(requestID: 1, kind: .available, mediaType: .tv, tmdbID: 1, seasons: [2], jellyfinItemID: "x", title: "Show", posterPath: nil, date: t1)
        let merged = MyRequestEvent.merging([b], into: [a])
        #expect(merged.count == 1)
        #expect(merged[0].seasons == [1, 2])
        #expect(merged[0].jellyfinItemID == "x")
    }
}
