import Foundation
import Observation

/// Source-neutral person header. TMDB supplies the richer version through Seerr, Jellyfin's own
/// person item supplies the reduced one when Seerr is absent or unreachable (Sodalite#57).
struct PersonProfile: Equatable, Sendable {
    var name: String
    var biography: String?
    var knownForDepartment: String?
    /// TMDB profile path, set only on the Seerr-sourced profile.
    var tmdbProfilePath: String?
    /// Jellyfin person item and its primary image tag, set only on the Jellyfin-sourced profile.
    var jellyfinPersonID: String?
    var jellyfinImageTag: String?

    init(seerr detail: SeerrPersonDetail) {
        name = detail.name
        biography = detail.biography
        knownForDepartment = detail.knownForDepartment
        tmdbProfilePath = detail.profilePath
    }

    init(jellyfin item: JellyfinItem) {
        name = item.name
        biography = item.overview
        jellyfinPersonID = item.id
        jellyfinImageTag = item.imageTags?.primary
    }
}

/// Loading and failure policy for the person page. The page has two independent halves, the library
/// rows from Jellyfin and the profile plus filmography from Seerr, and it stays useful when either
/// one is missing: with no Seerr it degrades to a Jellyfin-only page instead of an error screen.
@MainActor
@Observable
final class PersonDetailViewModel {
    private(set) var profile: PersonProfile?
    private(set) var filmography: [SeerrMedia] = []
    private(set) var library: PersonLibraryResults = .empty
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var filmographyState: FilmographyState = .loaded

    /// What the page can say about the TMDB half. `hidden` is Seerr switched off for browsing:
    /// there is no filmography to be missing, so the heading goes rather than claiming the person
    /// has no titles. `unavailable` is Seerr switched on and unable to deliver, which the page says
    /// out loud instead of reading like an app that cannot show a filmography at all (Sodalite#143).
    enum FilmographyState: Equatable {
        case loaded
        case hidden
        case unavailable(String)
    }

    private let itemService: JellyfinItemServiceProtocol
    private let mediaService: SeerrMediaServiceProtocol
    private let searchService: SeerrSearchServiceProtocol
    private let isSeerrConnected: Bool
    private let userID: String?
    /// Kept so a retry does not pay for the id translation a second time.
    private var resolvedTMDBID: Int?

    init(
        itemService: JellyfinItemServiceProtocol,
        mediaService: SeerrMediaServiceProtocol,
        searchService: SeerrSearchServiceProtocol,
        isSeerrConnected: Bool,
        userID: String?
    ) {
        self.itemService = itemService
        self.mediaService = mediaService
        self.searchService = searchService
        self.isSeerrConnected = isSeerrConnected
        self.userID = userID
    }

    /// `tmdbID` from a Seerr-sourced entry point, `jellyfinPersonID` from a library cast row; the
    /// page is opened with whichever one the caller had and resolves the other side here.
    /// `sourceTMDBID` is the title the tap came from, used only to tell same-named people apart.
    func load(tmdbID: Int?, jellyfinPersonID: String?, name: String, sourceTMDBID: Int? = nil) async {
        isLoading = true
        errorMessage = nil
        filmographyState = .loaded
        defer { isLoading = false }

        // Both halves at once: the library rows never wait on Seerr, and a Seerr failure never
        // costs the rows.
        async let librarySide = loadLibrary(jellyfinPersonID: jellyfinPersonID, tmdbID: tmdbID, name: name)
        async let seerrSide = loadSeerr(
            tmdbID: tmdbID, jellyfinPersonID: jellyfinPersonID, name: name, sourceTMDBID: sourceTMDBID
        )

        let (libraryPersonID, results) = await librarySide
        let seerr = await seerrSide

        library = results

        switch seerr {
        case .loaded(let detail, let credits):
            profile = PersonProfile(seerr: detail)
            filmography = Self.computeFilmography(from: credits)
        case .unavailable(let reason, let silent):
            filmographyState = silent ? .hidden : .unavailable(reason)
            // No TMDB half: Jellyfin's own person item still carries a name, a photo and a bio.
            if let libraryPersonID,
               let userID,
               let item = try? await itemService.getItemDetail(userID: userID, itemID: libraryPersonID) {
                profile = PersonProfile(jellyfin: item)
            }
            if profile == nil && library.isEmpty {
                errorMessage = reason
            }
        }
    }

    private enum SeerrOutcome {
        case loaded(SeerrPersonDetail, SeerrPersonCredits?)
        /// Carries the message to show if the Jellyfin side turns up nothing either. `silent` marks
        /// the switched-off case, the one failure the page drops rather than explains.
        case unavailable(String, silent: Bool)
    }

    private func loadSeerr(
        tmdbID: Int?,
        jellyfinPersonID: String?,
        name: String,
        sourceTMDBID: Int?
    ) async -> SeerrOutcome {
        guard isSeerrConnected else {
            return .unavailable(String(
                localized: "person.seerrNotConnected",
                defaultValue: "Seerr is not connected. Connect Seerr in Settings to view this page."
            ), silent: true)
        }
        guard let id = await personTMDBID(
            tmdbID: tmdbID, jellyfinPersonID: jellyfinPersonID, name: name, sourceTMDBID: sourceTMDBID
        ) else {
            return .unavailable(String(
                localized: "person.noTmdbID",
                defaultValue: "This person could not be matched to TMDB, so there is no filmography to show."
            ), silent: false)
        }
        do {
            async let detail = mediaService.personDetail(tmdbID: id)
            async let credits = mediaService.personCredits(tmdbID: id)
            return .loaded(try await detail, try? await credits)
        } catch {
            return .unavailable(ErrorText.user(for: error), silent: false)
        }
    }

    private func loadLibrary(
        jellyfinPersonID: String?,
        tmdbID: Int?,
        name: String
    ) async -> (String?, PersonLibraryResults) {
        guard let userID else { return (nil, .empty) }
        guard let personID = await PersonLibrary.resolvePersonID(
            itemService: itemService,
            userID: userID,
            jellyfinPersonID: jellyfinPersonID,
            name: name,
            tmdbID: tmdbID ?? resolvedTMDBID
        ) else { return (nil, .empty) }
        let results = await PersonLibrary.load(
            itemService: itemService, userID: userID, personID: personID
        )
        return (personID, results)
    }

    /// Jellyfin's item response carries no provider ids for cast, so a Jellyfin-sourced person costs
    /// one lookup to reach TMDB. Libraries built from local metadata routinely hold people with no
    /// provider id at all, and those used to end the page at the library rows with no filmography
    /// and no reason given, which is what Sodalite#143 reported; a name search on Seerr is the
    /// second chance. Both run inside `load()` so the spinner covers them.
    private func personTMDBID(
        tmdbID: Int?,
        jellyfinPersonID: String?,
        name: String,
        sourceTMDBID: Int?
    ) async -> Int? {
        if let tmdbID { return tmdbID }
        if let resolvedTMDBID { return resolvedTMDBID }
        if let jellyfinPersonID, let userID,
           let person = try? await itemService.getItemDetail(userID: userID, itemID: jellyfinPersonID),
           let id = person.tmdbID {
            resolvedTMDBID = id
            return id
        }
        resolvedTMDBID = await searchedTMDBID(name: name, sourceTMDBID: sourceTMDBID)
        return resolvedTMDBID
    }

    private func searchedTMDBID(name: String, sourceTMDBID: Int?) async -> Int? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        guard let results = try? await searchService.search(query: query, page: 1) else { return nil }
        return PersonTMDBMatch.resolve(in: results.people, name: query, sourceTMDBID: sourceTMDBID)
    }

    /// cast + crew, deduped by stableKey, poster-only, newest first. Computed once when credits land
    /// rather than re-deduped and re-sorted on every body pass.
    static func computeFilmography(from credits: SeerrPersonCredits?) -> [SeerrMedia] {
        let all = (credits?.cast ?? []) + (credits?.crew ?? [])
        var seen = Set<String>()
        let deduped = all.filter { seen.insert($0.stableKey).inserted }
        return deduped
            .filter { $0.posterPath != nil }
            .sorted {
                ($0.releaseDate ?? $0.firstAirDate ?? "")
                    > ($1.releaseDate ?? $1.firstAirDate ?? "")
            }
    }
}
