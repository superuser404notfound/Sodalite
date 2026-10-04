import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    var jellyfinResults: [JellyfinItem] = []
    var seerrResults: [SeerrMedia] = []
    /// People from the same Seerr search; they route to the person page, not to a request (Sodalite#56).
    var peopleResults: [SeerrPersonSearchResult] = []
    var isSearching = false
    var errorMessage: String?

    private let itemService: JellyfinItemServiceProtocol
    /// `var` so SearchView can flip nil→service when Seerr connects after the search tab is already open; otherwise a cold-start tap pins the catalog half at nil for the session.
    var seerrSearchService: SeerrSearchServiceProtocol?
    private let userID: String
    /// Servers a search runs against, active first; one unless servers are combined (Sodalite#85).
    var sources: [SearchSource]
    /// How long a secondary server gets before a search leaves it out.
    var secondaryDeadline: Duration = .seconds(4)
    private var searchTask: Task<Void, Never>?

    /// Monotonic in-flight search ID; only the run still matching `currentSearchID` may publish. `Task.isCancelled` alone is insufficient since network helpers swallow cancellation into `[]`, which would wipe a newer search's results.
    private var currentSearchID: UInt64 = 0

    init(
        itemService: JellyfinItemServiceProtocol,
        seerrSearchService: SeerrSearchServiceProtocol?,
        userID: String,
        sources: [SearchSource]? = nil
    ) {
        self.itemService = itemService
        self.seerrSearchService = seerrSearchService
        self.userID = userID
        self.sources = sources ?? [SearchSource(serverID: "", userID: userID, itemService: itemService, isActive: true)]
    }

    /// Debounced search; cancels the prior task so fast typing only runs the final query (saves bandwidth, avoids out-of-order results).
    func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            // Bump the ID so in-flight tasks can't write; the cleared state owns the newest "search".
            currentSearchID &+= 1
            jellyfinResults = []
            seerrResults = []
            peopleResults = []
            isSearching = false
            errorMessage = nil
            return
        }

        currentSearchID &+= 1
        let id = currentSearchID

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.runSearch(query: trimmed, id: id)
        }
    }

    private func runSearch(query: String, id: UInt64) async {
        isSearching = true
        errorMessage = nil

        async let jfTask = searchJellyfin(query: query)
        async let seerrTask = searchSeerr(query: query)

        let jfResult = await jfTask
        let seerrResult = await seerrTask

        // Publish only if still the latest search; a superseded run must not overwrite results nor flip isSearching to false while a fresher run is mid-flight.
        guard id == currentSearchID else { return }

        let jfItems = jfResult.items
        jellyfinResults = jfItems
        seerrResults = deduplicate(seerr: seerrResult.media, against: jfItems)
        peopleResults = seerrResult.people
        isSearching = false

        // Connection failure vs "no results": Jellyfin is the primary signal; only its error + every list empty means network problem. Seerr alone can't trigger this (may be intentionally disconnected).
        if jfResult.error != nil && jellyfinResults.isEmpty && seerrResults.isEmpty && peopleResults.isEmpty {
            errorMessage = String(
                localized: "search.error.connection",
                defaultValue: "Couldn't reach your server. Check the connection and try again."
            )
        }
    }

    private struct ServiceResult<T> {
        let items: [T]
        let error: Error?
    }

    private func searchJellyfin(query: String) async -> ServiceResult<JellyfinItem> {
        let q = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 30,
            searchTerm: query,
            fields: JellyfinEndpoint.homeRowFields
        )
        guard sources.count > 1 else {
            do {
                let resp = try await sources[0].itemService.getCollectionItems(userID: sources[0].userID, query: q)
                return ServiceResult(items: resp.items, error: nil)
            } catch {
                return ServiceResult(items: [], error: error)
            }
        }
        // Every server at once; a secondary that fails or misses the deadline is left out quietly,
        // only the active server's failure counts as "couldn't reach your server" (Sodalite#85).
        let deadline = secondaryDeadline
        var outcomes: [Int: Result<[JellyfinItem], Error>?] = [:]
        await withTaskGroup(of: (Int, Result<[JellyfinItem], Error>?).self) { group in
            for (index, source) in sources.enumerated() {
                let run: @MainActor @Sendable () async -> Result<[JellyfinItem], Error> = {
                    do { return .success(try await source.itemService.getCollectionItems(userID: source.userID, query: q).items) }
                    catch { return .failure(error) }
                }
                let isActive = source.isActive
                group.addTask {
                    (index, isActive ? await run() : await Deadline.race(deadline) { await run() })
                }
            }
            for await (index, result) in group { outcomes[index] = result }
        }
        var answered: [[JellyfinItem]] = []
        var activeError: Error?
        for (index, source) in sources.enumerated() {
            switch outcomes[index] ?? nil {
            case .success(let items)?:
                answered.append(items.map { item in
                    var stamped = item
                    if stamped.serverID == nil { stamped.serverID = source.serverID }
                    return stamped
                })
            case .failure(let error)?:
                if source.isActive { activeError = error }
            case nil:
                break
            }
        }
        let merged = HomeMerger.merge(answered, type: .allMovies, mergedContinueWatching: false)
        return ServiceResult(items: Array(merged.prefix(30)), error: answered.isEmpty ? activeError : nil)
    }

    /// Two lists rather than one `ServiceResult`: the same response feeds the catalog row and the people row.
    private struct SeerrSearchOutcome {
        let media: [SeerrMedia]
        let people: [SeerrPersonSearchResult]
        let error: Error?

        static let none = SeerrSearchOutcome(media: [], people: [], error: nil)
    }

    private func searchSeerr(query: String) async -> SeerrSearchOutcome {
        guard let service = seerrSearchService else { return .none }
        do {
            let result = try await service.search(query: query, page: 1)
            return SeerrSearchOutcome(media: result.media, people: result.people, error: nil)
        } catch {
            return SeerrSearchOutcome(media: [], people: [], error: error)
        }
    }

    /// Remove Seerr results the library already answers for. Shared with the detail pages' catalog row, see SeerrLibraryDedupe.
    private func deduplicate(seerr: [SeerrMedia], against jellyfin: [JellyfinItem]) -> [SeerrMedia] {
        SeerrLibraryDedupe.removing(seerr, matching: jellyfin)
    }
}
