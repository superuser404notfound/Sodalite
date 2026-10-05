import Testing
import Foundation
@testable import Sodalite

/// The request draft is what the request sheet edits and submits, pulled out of CatalogDetailView so
/// the rules (what may be submitted, what goes in the payload, what gets preselected) are checkable
/// without a view (Sodalite#132).
@MainActor
struct SeerrRequestDraftTests {

    // MARK: - Fixtures

    private func season(_ n: Int) -> SeerrSeason {
        SeerrSeason(
            id: n * 100,
            seasonNumber: n,
            name: "Season \(n)",
            overview: nil,
            episodeCount: 10,
            airDate: nil,
            posterPath: nil
        )
    }

    private func details(
        serverID: Int = 3,
        activeProfileID: Int? = 7,
        activeDirectory: String? = "/tv",
        languageProfileID: Int? = 9,
        profileIDs: [Int] = [7, 8],
        rootFolders: [String] = ["/tv", "/tv-4k"]
    ) -> SeerrServiceDetails {
        SeerrServiceDetails(
            server: SeerrServiceServer(
                id: serverID,
                name: "Sonarr",
                isDefault: true,
                is4k: false,
                activeProfileId: activeProfileID,
                activeDirectory: activeDirectory,
                activeLanguageProfileId: languageProfileID
            ),
            profiles: profileIDs.map { SeerrQualityProfile(id: $0, name: "P\($0)") },
            rootFolders: rootFolders.enumerated().map { SeerrRootFolder(id: $0.offset, path: $0.element, freeSpace: nil) },
            languageProfiles: nil,
            tags: [SeerrTag(id: 1, label: "kids"), SeerrTag(id: 2, label: "german")]
        )
    }

    private final class CreateSpy: SeerrRequestServiceProtocol, @unchecked Sendable {
        struct Call {
            let mediaType: SeerrMediaType
            let tmdbID: Int
            let seasons: [Int]?
            let serverID: Int?
            let profileID: Int?
            let rootFolder: String?
            let languageProfileID: Int?
            let tags: [Int]?
        }
        var calls: [Call] = []
        var throwsOnCreate: Error?

        func createRequest(
            mediaType: SeerrMediaType, tmdbID: Int, seasons: [Int]?, serverID: Int?,
            profileID: Int?, rootFolder: String?, languageProfileID: Int?, tags: [Int]?
        ) async throws -> SeerrRequest {
            calls.append(Call(
                mediaType: mediaType, tmdbID: tmdbID, seasons: seasons, serverID: serverID,
                profileID: profileID, rootFolder: rootFolder,
                languageProfileID: languageProfileID, tags: tags
            ))
            if let throwsOnCreate { throw throwsOnCreate }
            let json = #"{"id": 1, "status": 1, "type": "tv"}"#
            return try JSONDecoder().decode(SeerrRequest.self, from: Data(json.utf8))
        }
        func myRequests(userID: Int, take: Int, skip: Int, sort: SeerrRequestSort) async throws -> SeerrRequestsResult { throw Boom() }
        func allRequests(filter: SeerrRequestFilter, take: Int, skip: Int) async throws -> SeerrRequestsResult { throw Boom() }
        func approveRequest(requestID: Int) async throws -> SeerrRequest { throw Boom() }
        func declineRequest(requestID: Int) async throws -> SeerrRequest { throw Boom() }
        func deleteRequest(requestID: Int) async throws { throw Boom() }
        func updateRequest(requestID: Int, body: SeerrRequestUpdateBody) async throws -> SeerrRequest { throw Boom() }
    }

    private final class ConfigSpy: SeerrServiceConfigServiceProtocol, @unchecked Sendable {
        var sonarrDetailsToReturn: SeerrServiceDetails?
        var servers: [SeerrServiceServer] = []
        var sonarrServerCalls = 0
        var sonarrDetailCalls = 0

        func radarrServers() async throws -> [SeerrServiceServer] { servers }
        func radarrDetails(serverID: Int) async throws -> SeerrServiceDetails { throw Boom() }
        func sonarrServers() async throws -> [SeerrServiceServer] {
            sonarrServerCalls += 1
            return servers
        }
        func sonarrDetails(serverID: Int) async throws -> SeerrServiceDetails {
            sonarrDetailCalls += 1
            guard let sonarrDetailsToReturn else { throw Boom() }
            return sonarrDetailsToReturn
        }
    }

    private struct Boom: Error {}

    // MARK: - What may be submitted

    @Test func aMovieNeedsNoSelection() {
        let draft = SeerrRequestDraft(mediaType: .movie, tmdbID: 42)
        #expect(draft.canSubmit)
        #expect(draft.seasonsPayload == nil)
    }

    @Test func aSeriesWithNoSeasonPickedCannotBeSubmitted() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1), season(2)]
        #expect(draft.canSubmit == false)
        draft.toggle(1)
        #expect(draft.canSubmit)
    }

    /// Jellyseerr takes whole seasons and answers 202 for a payload it cannot place, so the payload
    /// carries exactly what was ticked, in order.
    @Test func theSeasonPayloadIsSortedAndOnlyWhatWasPicked() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1), season(2), season(3)]
        draft.toggle(3)
        draft.toggle(1)
        #expect(draft.seasonsPayload == [1, 3])
    }

    // MARK: - Selection

    @Test func selectAllCoversEverySeasonAndClearingUndoesIt() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1), season(2), season(3)]
        draft.selectAll()
        #expect(draft.allSeasonsSelected)
        #expect(draft.seasonsPayload == [1, 2, 3])
        draft.clearSelection()
        #expect(draft.allSeasonsSelected == false)
        #expect(draft.seasonsPayload == nil)
    }

    /// A stale pick from a season list that has since changed must not keep the all-row ticked, or
    /// "deselect all" would be offered for a set that is not all of anything.
    @Test func allSelectedIgnoresSeasonsThatAreNoLongerOffered() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1), season(2)]
        draft.selectAll()
        draft.seasons = [season(1), season(2), season(3)]
        #expect(draft.allSeasonsSelected == false)
    }

    @Test func togglingTwiceLeavesNothingBehind() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1)]
        draft.toggle(1)
        draft.toggle(1)
        #expect(draft.selectedSeasons.isEmpty)
    }

    // MARK: - Preselection

    /// The sheet opens actionable: everything the server does not already have, or is not already
    /// fetching, starts ticked. A season that is there or on its way does not.
    @Test func seedingPreselectsWhatIsWorthRequesting() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        let statuses: [Int: SeerrMediaStatus?] = [
            1: nil,
            2: .available,
            3: .processing,
            4: .pending,
            5: .partiallyAvailable,
            6: .deleted,
            7: .unknown,
        ]
        draft.seed(seasons: (1...7).map(season), status: { statuses[$0] ?? nil })
        #expect(draft.selectedSeasons == [1, 6, 7])
    }

    /// Nothing left to ask for: the sheet still opens (the options are worth seeing), but its primary
    /// action stays disabled instead of submitting an empty request.
    @Test func aFullyAvailableSeriesPreselectsNothing() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seed(seasons: [season(1), season(2)], status: { _ in .available })
        #expect(draft.selectedSeasons.isEmpty)
        #expect(draft.canSubmit == false)
    }

    /// Reopening the sheet must not wipe a selection the user has already adjusted.
    @Test func seedingIsIdempotentOnceItRan() {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seed(seasons: [season(1), season(2)], status: { _ in nil })
        draft.toggle(1)
        draft.seed(seasons: [season(1), season(2)], status: { _ in nil })
        #expect(draft.selectedSeasons == [2])
    }

    // MARK: - Submitting

    @Test func submitSendsTheResolvedServerAndOptions() async {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.options.details = details()
        draft.options.profileID = 8
        draft.options.rootFolder = "/tv-4k"
        draft.options.tagIDs = [2, 1]
        draft.seasons = [season(1), season(2)]
        draft.toggle(2)

        let spy = CreateSpy()
        let ok = await draft.submit(service: spy)

        #expect(ok)
        #expect(draft.didSubmit)
        #expect(draft.error == nil)
        #expect(spy.calls.count == 1)
        let call = spy.calls[0]
        #expect(call.mediaType == .tv)
        #expect(call.tmdbID == 42)
        #expect(call.seasons == [2])
        #expect(call.serverID == 3)
        #expect(call.profileID == 8)
        #expect(call.rootFolder == "/tv-4k")
        #expect(call.languageProfileID == nil)
        #expect(call.tags == [1, 2])
    }

    // MARK: - Routing left to Seerr (audit 2026-09-25 CL-2)

    private func resolvedOptions(_ config: ConfigSpy) async -> SeerrRequestOptions {
        let options = SeerrRequestOptions()
        await options.load(service: config, mediaType: .tv)
        return options
    }

    private func defaultConfig() -> ConfigSpy {
        let config = ConfigSpy()
        config.servers = [SeerrServiceServer(
            id: 3, name: "Sonarr", isDefault: true, is4k: false,
            activeProfileId: 7, activeDirectory: "/tv", activeLanguageProfileId: 9
        )]
        config.sonarrDetailsToReturn = details()
        return config
    }

    /// Any routing field Seerr receives is an override: it replaces the anime profile and folder, the
    /// Override Rules and the tier's default server. Untouched defaults therefore stay out of the body.
    @Test func untouchedDefaultsLeaveTheRoutingToSeerr() async {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42, options: await resolvedOptions(defaultConfig()))
        #expect(draft.options.profileID == 7)
        draft.seasons = [season(1)]
        draft.toggle(1)
        let spy = CreateSpy()
        _ = await draft.submit(service: spy)

        let call = spy.calls[0]
        #expect(call.serverID == nil)
        #expect(call.profileID == nil)
        #expect(call.rootFolder == nil)
        #expect(call.languageProfileID == nil)
    }

    @Test func onlyWhatTheUserChangedIsSent() async {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42, options: await resolvedOptions(defaultConfig()))
        draft.options.profileID = 8
        draft.seasons = [season(1)]
        draft.toggle(1)
        let spy = CreateSpy()
        _ = await draft.submit(service: spy)

        let call = spy.calls[0]
        #expect(call.serverID == nil)
        #expect(call.profileID == 8)
        #expect(call.rootFolder == nil)
    }

    /// A stale configured profile would fail in Sonarr, so the validated fallback does go out.
    @Test func aValidatedFallbackIsStillSent() async {
        let config = defaultConfig()
        config.servers = [SeerrServiceServer(
            id: 3, name: "Sonarr", isDefault: true, is4k: false,
            activeProfileId: 999, activeDirectory: "/tv", activeLanguageProfileId: 9
        )]
        config.sonarrDetailsToReturn = details(activeProfileID: 999)
        let options = await resolvedOptions(config)
        #expect(options.profileIDPayload == 7)
        #expect(options.rootFolderPayload == nil)
    }

    /// The request goes out without `is4k`, so the 4K default listed first must not be the server whose
    /// options are shown, or whose id is sent.
    @Test func theFourKDefaultIsNotTheStandardRequestsServer() {
        let uhd = SeerrServiceServer(id: 1, name: "4K", isDefault: true, is4k: true,
                                     activeProfileId: 1, activeDirectory: "/4k", activeLanguageProfileId: nil)
        let hd = SeerrServiceServer(id: 2, name: "HD", isDefault: true, is4k: false,
                                    activeProfileId: 2, activeDirectory: "/hd", activeLanguageProfileId: nil)
        #expect(SeerrRequestDefaults.chooseServer(from: [uhd, hd])?.id == 2)
    }

    /// Without a non-4K default Seerr would drop the request, so the server Sodalite fell back to is named.
    @Test func aFallbackServerIsNamedInTheRequest() async {
        let config = defaultConfig()
        config.servers = [SeerrServiceServer(
            id: 3, name: "Sonarr", isDefault: false, is4k: false,
            activeProfileId: 7, activeDirectory: "/tv", activeLanguageProfileId: 9
        )]
        let options = await resolvedOptions(config)
        #expect(options.serverIDPayload == 3)
        #expect(options.profileIDPayload == nil)
    }

    /// Older Jellyseerr has no tags field, so "no tags" has to be absent, not an empty array.
    @Test func noTagsMeansNoTagsField() async {
        let draft = SeerrRequestDraft(mediaType: .movie, tmdbID: 7)
        draft.options.details = details()
        let spy = CreateSpy()
        _ = await draft.submit(service: spy)
        #expect(spy.calls[0].tags == nil)
        #expect(spy.calls[0].seasons == nil)
    }

    @Test func aFailedSubmitKeepsTheDraftAndSurfacesTheMessage() async {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1)]
        draft.toggle(1)
        let spy = CreateSpy()
        spy.throwsOnCreate = SeerrRequestError.noSeasonsAvailable

        let ok = await draft.submit(service: spy)

        #expect(ok == false)
        #expect(draft.didSubmit == false)
        #expect(draft.error != nil)
        #expect(draft.isSubmitting == false)
        #expect(draft.selectedSeasons == [1])
    }

    @Test func submitRefusesWhenNothingIsPicked() async {
        let draft = SeerrRequestDraft(mediaType: .tv, tmdbID: 42)
        draft.seasons = [season(1)]
        let spy = CreateSpy()
        let ok = await draft.submit(service: spy)
        #expect(ok == false)
        #expect(spy.calls.isEmpty)
    }

    // MARK: - Options

    /// Jellyseerr's `activeProfileId` can be stale; the resolved default has to exist in the profile
    /// list the server actually returned, or the request ships an id Sonarr rejects.
    @Test func loadingOptionsValidatesTheServerDefaults() async {
        let config = ConfigSpy()
        config.servers = [SeerrServiceServer(
            id: 3, name: "Sonarr", isDefault: true, is4k: false,
            activeProfileId: 999, activeDirectory: "/gone", activeLanguageProfileId: 9
        )]
        config.sonarrDetailsToReturn = details(activeProfileID: 999, activeDirectory: "/gone")

        let options = SeerrRequestOptions()
        await options.load(service: config, mediaType: .tv)

        #expect(options.profileID == 7)
        #expect(options.rootFolder == "/tv")
        #expect(options.details != nil)
        #expect(options.isLoading == false)
    }

    /// The collection page is handed the options the pushing detail page already resolved; resolving
    /// them again is two more round trips against a live Radarr for no new answer.
    @Test func seededOptionsAreNotResolvedAgain() async {
        let config = ConfigSpy()
        config.sonarrDetailsToReturn = details()
        let options = SeerrRequestOptions(details: details(), profileID: 8, rootFolder: "/tv-4k")

        await options.load(service: config, mediaType: .tv)

        #expect(config.sonarrServerCalls == 0)
        #expect(config.sonarrDetailCalls == 0)
        #expect(options.profileID == 8)
    }

    /// A Seerr without a configured Sonarr must leave the request submittable on server defaults, not
    /// wedge the sheet in its loading state.
    @Test func aServerlessSeerrLeavesTheOptionsEmptyAndDone() async {
        let config = ConfigSpy()
        let options = SeerrRequestOptions()
        await options.load(service: config, mediaType: .tv)
        #expect(options.details == nil)
        #expect(options.isLoading == false)
    }
}
