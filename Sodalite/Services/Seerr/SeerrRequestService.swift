import Foundation

/// Jellyseerr's POST /request signals some failures inside the 2xx range: NoSeasonsAvailableError comes back as 202 + `{status, message}` when every selected season is already requested, processing, or available. Without dedicated handling those bodies die in the SeerrRequest decode as a generic "could not process server response".
enum SeerrRequestError: LocalizedError, Equatable {
    case noSeasonsAvailable
    /// 201 whose body is a request object without a top-level `id`: Jellyseerr auto-approved, failed the Sonarr/Radarr handover (e.g. the series has no TVDB entry yet), and removed the just-created request before serializing it (TypeORM's remove() strips the id).
    case requestDiscarded
    case serverRejected(message: String)

    var errorDescription: String? {
        switch self {
        case .noSeasonsAvailable:
            String(
                localized: "error.seerr.noSeasonsAvailable",
                defaultValue: "All selected seasons have already been requested or are already available"
            )
        case .requestDiscarded:
            String(
                localized: "error.seerr.requestDiscarded",
                defaultValue: "The server discarded the request because it could not be handed over to Sonarr/Radarr. Very new titles are often not requestable yet."
            )
        case .serverRejected(let message):
            message
        }
    }
}

private struct SeerrErrorBody: Decodable {
    let message: String?
}

private struct SeerrDiscardedRequestProbe: Decodable {
    struct AnyObjectStub: Decodable {}
    let id: Int?
    let type: SeerrMediaType?
    let media: AnyObjectStub?
}

protocol SeerrRequestServiceProtocol: Sendable {
    func createRequest(
        mediaType: SeerrMediaType,
        tmdbID: Int,
        seasons: [Int]?,
        serverID: Int?,
        profileID: Int?,
        rootFolder: String?,
        languageProfileID: Int?,
        tags: [Int]?
    ) async throws -> SeerrRequest

    func myRequests(userID: Int, take: Int, skip: Int, sort: SeerrRequestSort) async throws -> SeerrRequestsResult

    /// Admin queue (all users, status-filtered); needs MANAGE_REQUESTS/ADMIN in `SeerrUser.permissions`. A revoked permission surfaces 403 as `APIError.unauthorized`.
    func allRequests(
        filter: SeerrRequestFilter,
        take: Int,
        skip: Int
    ) async throws -> SeerrRequestsResult

    @discardableResult
    func approveRequest(requestID: Int) async throws -> SeerrRequest

    @discardableResult
    func declineRequest(requestID: Int) async throws -> SeerrRequest

    func deleteRequest(requestID: Int) async throws

    @discardableResult
    func updateRequest(
        requestID: Int,
        body: SeerrRequestUpdateBody
    ) async throws -> SeerrRequest
}

@MainActor
final class SeerrRequestService: SeerrRequestServiceProtocol {
    private let client: SeerrClient

    init(client: SeerrClient) {
        self.client = client
    }

    func createRequest(
        mediaType: SeerrMediaType,
        tmdbID: Int,
        seasons: [Int]? = nil,
        serverID: Int? = nil,
        profileID: Int? = nil,
        rootFolder: String? = nil,
        languageProfileID: Int? = nil,
        tags: [Int]? = nil
    ) async throws -> SeerrRequest {
        let body = SeerrCreateRequestBody(
            mediaType: mediaType,
            mediaId: tmdbID,
            seasons: seasons,
            serverId: serverID,
            profileId: profileID,
            rootFolder: rootFolder,
            languageProfileId: languageProfileID,
            tags: tags
        )
        let (data, response) = try await client.requestData(
            endpoint: SeerrEndpoint.createRequest(body: body)
        )
        if response.statusCode == 202 {
            throw SeerrRequestError.noSeasonsAvailable
        }
        do {
            return try client.decode(SeerrRequest.self, from: data)
        } catch {
            // Field-debuggable via the Support log: a 2xx that is neither a request object nor a {message} error body is otherwise invisible.
            LogTap.shared.note(
                "[seerr] createRequest undecodable: HTTP \(response.statusCode), \(data.count) bytes, error: \(error)"
            )
            LogTap.shared.note(
                "[seerr] createRequest body: \(String(decoding: data.prefix(4096), as: UTF8.self))"
            )
            // Unknown 2xx error variant: show the server's own message over a generic decode failure.
            if let message = (try? client.decode(SeerrErrorBody.self, from: data))?.message {
                throw SeerrRequestError.serverRejected(message: message)
            }
            if let probe = try? client.decode(SeerrDiscardedRequestProbe.self, from: data),
               probe.id == nil, probe.type != nil, probe.media != nil {
                throw SeerrRequestError.requestDiscarded
            }
            throw error
        }
    }

    func myRequests(userID: Int, take: Int = 50, skip: Int = 0, sort: SeerrRequestSort = .added) async throws -> SeerrRequestsResult {
        try await client.request(
            endpoint: SeerrEndpoint.myRequests(userID: userID, take: take, skip: skip, sort: sort),
            responseType: SeerrRequestsResult.self
        )
    }

    func allRequests(
        filter: SeerrRequestFilter,
        take: Int = 50,
        skip: Int = 0
    ) async throws -> SeerrRequestsResult {
        try await client.request(
            endpoint: SeerrEndpoint.allRequests(filter: filter, take: take, skip: skip),
            responseType: SeerrRequestsResult.self
        )
    }

    @discardableResult
    func approveRequest(requestID: Int) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.approveRequest(requestID: requestID),
            responseType: SeerrRequest.self
        )
    }

    @discardableResult
    func declineRequest(requestID: Int) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.declineRequest(requestID: requestID),
            responseType: SeerrRequest.self
        )
    }

    func deleteRequest(requestID: Int) async throws {
        try await client.request(
            endpoint: SeerrEndpoint.deleteRequest(requestID: requestID)
        )
    }

    @discardableResult
    func updateRequest(
        requestID: Int,
        body: SeerrRequestUpdateBody
    ) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.updateRequest(requestID: requestID, body: body),
            responseType: SeerrRequest.self
        )
    }
}
