import Foundation

/// The Radarr / Sonarr side of a request: which instance takes it, at which quality, into which folder,
/// with which tags. Shared by the single-title request sheet and the collection bulk request, which
/// used to keep the same four fields as separate view state each (Sodalite#132).
@MainActor
@Observable
final class SeerrRequestOptions {
    var details: SeerrServiceDetails?
    var profileID: Int?
    var rootFolder: String?
    var tagIDs: Set<Int> = []
    /// What Seerr would do with the field left out. Every routing field Seerr receives is an override: it
    /// beats the anime profile and folder, the Override Rules and the 4K/non-4K server choice
    /// (MediaRequestSubscriber, MediaRequest.request), so a value still equal to this is not sent.
    private(set) var implicit: SeerrRequestDefaults.Implicit?
    /// Distinguishes "still resolving" from "this server offers no options", which an empty section cannot.
    private(set) var isLoading = false

    /// Seeded from the page that pushed this one, where it already resolved them.
    init(
        details: SeerrServiceDetails? = nil,
        profileID: Int? = nil,
        rootFolder: String? = nil,
        implicit: SeerrRequestDefaults.Implicit? = nil
    ) {
        self.details = details
        self.profileID = profileID
        self.rootFolder = rootFolder
        self.implicit = implicit
    }

    /// The instance rides along with the resolved server, it is never picked by hand.
    var serverID: Int? { details?.server.id }

    /// Without a resolved baseline everything set counts as chosen.
    var serverIDPayload: Int? {
        implicit?.serverIsSeerrDefault == true ? nil : serverID
    }

    var profileIDPayload: Int? {
        guard let implicit else { return profileID }
        return profileID == implicit.profileID ? nil : profileID
    }

    var rootFolderPayload: String? {
        guard let implicit else { return rootFolder }
        return rootFolder == implicit.rootFolder ? nil : rootFolder
    }

    /// Send nil, not [], for "no tags": older Jellyseerr lacks the field entirely.
    var tagsPayload: [Int]? {
        tagIDs.isEmpty ? nil : tagIDs.sorted()
    }

    var availableTags: [SeerrTag] {
        details?.tags ?? []
    }

    /// Best-effort: a Seerr with no Radarr/Sonarr configured, or a lookup that fails, leaves the fields
    /// empty and the request goes out on the server's own defaults.
    func load(service: SeerrServiceConfigServiceProtocol, mediaType: SeerrMediaType) async {
        guard details == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let resolved = try await SeerrRequestDefaults.resolve(
                service: service,
                mediaType: mediaType
            ) else { return }
            details = resolved.details
            profileID = resolved.profileID
            rootFolder = resolved.rootFolder
            implicit = resolved.implicit
        } catch {
            // Swallow: the option rows simply stay absent.
        }
    }
}

/// One request in the making: the seasons it covers, the options it carries, and the one call that
/// posts it. Lives outside the view so the rules that used to be spread over CatalogDetailView's
/// `@State` (what may be submitted, what goes in the payload, what opens preselected) are one place
/// and can be tested without a screen.
@MainActor
@Observable
final class SeerrRequestDraft {
    let mediaType: SeerrMediaType
    let tmdbID: Int

    /// The seasons on offer, specials already filtered out by the page.
    var seasons: [SeerrSeason] = []
    private(set) var selectedSeasons: Set<Int> = []
    let options: SeerrRequestOptions

    private(set) var isSubmitting = false
    private(set) var didSubmit = false
    var error: String?

    /// One-shot, so reopening the sheet does not wipe a selection the user has since adjusted.
    private var didSeed = false

    init(mediaType: SeerrMediaType, tmdbID: Int, options: SeerrRequestOptions = SeerrRequestOptions()) {
        self.mediaType = mediaType
        self.tmdbID = tmdbID
        self.options = options
    }

    // MARK: - Selection

    /// A series request without a season is the one payload Jellyseerr cannot place, so it gates the
    /// primary action; a movie is always ready.
    var canSubmit: Bool {
        switch mediaType {
        case .movie: true
        case .tv: !selectedSeasons.isEmpty
        case .person, .unknown: false
        }
    }

    var seasonsPayload: [Int]? {
        guard mediaType == .tv, !selectedSeasons.isEmpty else { return nil }
        return selectedSeasons.sorted()
    }

    var allSeasonsSelected: Bool {
        guard !seasons.isEmpty else { return false }
        return seasons.allSatisfy { selectedSeasons.contains($0.seasonNumber) }
    }

    func isSelected(_ seasonNumber: Int) -> Bool {
        selectedSeasons.contains(seasonNumber)
    }

    func toggle(_ seasonNumber: Int) {
        if selectedSeasons.contains(seasonNumber) {
            selectedSeasons.remove(seasonNumber)
        } else {
            selectedSeasons.insert(seasonNumber)
        }
    }

    func selectAll() {
        selectedSeasons = Set(seasons.map(\.seasonNumber))
    }

    func clearSelection() {
        selectedSeasons.removeAll()
    }

    /// Fills the draft the first time the sheet opens: everything the server does not already have,
    /// and is not already fetching, starts ticked. That makes the sheet actionable on open (the old
    /// flow left the user hunting for a way to say which seasons they meant) while the primary action
    /// still names the count, so a wide selection is never silent.
    func seed(seasons: [SeerrSeason], status: (Int) -> SeerrMediaStatus?) {
        self.seasons = seasons
        guard !didSeed else { return }
        didSeed = true
        selectedSeasons = Set(
            seasons
                .map(\.seasonNumber)
                .filter { Self.isWorthRequesting(status($0)) }
        )
    }

    /// Availability and pipeline states say "not this one": present, half present, approved and on its
    /// way, or waiting for an admin. A deleted season is explicitly worth asking for again, which is
    /// the whole point of the Jellyfin ground-truth reconcile that produces it. So is a failed one.
    static func isWorthRequesting(_ status: SeerrMediaStatus?) -> Bool {
        switch status {
        case .none, .unknown, .deleted, .failed: true
        case .available, .partiallyAvailable, .processing, .pending: false
        }
    }

    // MARK: - Submitting

    /// Posts the request. Returns whether it landed, so the caller can close the sheet on success and
    /// leave it standing (with its message) on failure.
    @discardableResult
    func submit(service: SeerrRequestServiceProtocol) async -> Bool {
        guard canSubmit, !isSubmitting else { return false }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            _ = try await service.createRequest(
                mediaType: mediaType,
                tmdbID: tmdbID,
                seasons: seasonsPayload,
                serverID: options.serverIDPayload,
                profileID: options.profileIDPayload,
                rootFolder: options.rootFolderPayload,
                languageProfileID: nil,
                tags: options.tagsPayload
            )
            didSubmit = true
            return true
        } catch {
            self.error = ErrorText.user(for: error)
            return false
        }
    }
}

/// Resolves the default Radarr/Sonarr server and its profile/root-folder defaults for a request.
/// Jellyseerr's `activeProfileId` can be nil, 0 or stale, so the configured default is validated against the
/// profiles the server actually returned before it is used; an unvalidated id shipped in the request and failed.
enum SeerrRequestDefaults {
    struct Resolved {
        let details: SeerrServiceDetails
        let profileID: Int?
        let rootFolder: String?
        let implicit: Implicit
    }

    /// What Seerr picks on its own for a request that leaves the field out: the `isDefault` server of the
    /// request's tier and that server's configured profile and folder (or their anime variants, which the
    /// client cannot see). A validated fallback that differs from the configured value still goes out.
    struct Implicit: Equatable, Sendable {
        let serverIsSeerrDefault: Bool
        let profileID: Int?
        let rootFolder: String?
    }

    static func resolve(
        service: SeerrServiceConfigServiceProtocol,
        mediaType: SeerrMediaType
    ) async throws -> Resolved? {
        let servers: [SeerrServiceServer]
        switch mediaType {
        case .movie: servers = try await service.radarrServers()
        case .tv: servers = try await service.sonarrServers()
        case .person, .unknown: return nil
        }
        guard let chosen = chooseServer(from: servers) else { return nil }
        let details: SeerrServiceDetails
        switch mediaType {
        case .movie: details = try await service.radarrDetails(serverID: chosen.id)
        case .tv: details = try await service.sonarrDetails(serverID: chosen.id)
        case .person, .unknown: return nil
        }

        let configuredProfile = chosen.activeProfileId ?? details.server.activeProfileId
        let validProfileIDs = Set(details.profiles.map(\.id))
        let profileID = [chosen.activeProfileId, details.server.activeProfileId]
            .compactMap { $0 }
            .first(where: validProfileIDs.contains)
            ?? details.profiles.first?.id

        let configuredFolder = chosen.activeDirectory ?? details.server.activeDirectory
        let validRootFolders = Set(details.rootFolders.map(\.path))
        let rootFolder = [chosen.activeDirectory, details.server.activeDirectory]
            .compactMap { $0 }
            .first(where: validRootFolders.contains)
            ?? details.rootFolders.first?.path

        return Resolved(
            details: details,
            profileID: profileID,
            rootFolder: rootFolder,
            implicit: Implicit(
                serverIsSeerrDefault: isSeerrDefault(chosen),
                profileID: configuredProfile,
                rootFolder: configuredFolder
            )
        )
    }

    /// Sodalite never posts `is4k`, so its requests are standard quality and Seerr routes them to the
    /// non-4K default. Picking by `isDefault` alone chose whichever default came first, often the 4K one.
    static func chooseServer(from servers: [SeerrServiceServer]) -> SeerrServiceServer? {
        servers.first(where: isSeerrDefault)
            ?? servers.first(where: { $0.is4k != true })
            ?? servers.first
    }

    private static func isSeerrDefault(_ server: SeerrServiceServer) -> Bool {
        server.isDefault == true && server.is4k != true
    }
}
