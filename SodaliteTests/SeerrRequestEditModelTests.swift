import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 CL-1. Seerr's `PUT /request/{id}` is OpenAPI-validated with `required: [mediaType]`
/// and then ASSIGNS serverId/profileId/rootFolder/languageProfileId/tags from the body (seerr-team/seerr
/// v3.4.1, server/routes/request.ts). A diff body was rejected with 400; a diff body with mediaType would
/// have cleared the server and tags and pinned the first profile in the list.
@MainActor
struct SeerrRequestEditModelTests {

    private final class ConfigSpy: SeerrServiceConfigServiceProtocol, @unchecked Sendable {
        var servers: [SeerrServiceServer] = []
        var details: [Int: SeerrServiceDetails] = [:]
        var delays: [Int: Duration] = [:]
        func radarrServers() async throws -> [SeerrServiceServer] { servers }
        func radarrDetails(serverID: Int) async throws -> SeerrServiceDetails { try detail(serverID) }
        func sonarrServers() async throws -> [SeerrServiceServer] { servers }
        func sonarrDetails(serverID: Int) async throws -> SeerrServiceDetails {
            if let delay = delays[serverID] { try? await Task.sleep(for: delay) }
            return try detail(serverID)
        }
        private func detail(_ id: Int) throws -> SeerrServiceDetails {
            guard let d = details[id] else { throw URLError(.badServerResponse) }
            return d
        }
    }

    private func server(_ id: Int, isDefault: Bool, is4k: Bool, profile: Int, folder: String) -> SeerrServiceServer {
        SeerrServiceServer(id: id, name: "S\(id)", isDefault: isDefault, is4k: is4k,
                           activeProfileId: profile, activeDirectory: folder, activeLanguageProfileId: 1)
    }

    private func config() -> ConfigSpy {
        let spy = ConfigSpy()
        let hd = server(1, isDefault: true, is4k: false, profile: 10, folder: "/tv")
        let uhd = server(2, isDefault: true, is4k: true, profile: 20, folder: "/tv-4k")
        spy.servers = [uhd, hd]
        spy.details[1] = SeerrServiceDetails(
            server: hd,
            profiles: [SeerrQualityProfile(id: 9, name: "Any"), SeerrQualityProfile(id: 10, name: "HD"),
                       SeerrQualityProfile(id: 11, name: "Anime")],
            rootFolders: [SeerrRootFolder(id: 1, path: "/anime", freeSpace: nil),
                          SeerrRootFolder(id: 2, path: "/tv", freeSpace: nil)],
            languageProfiles: nil, tags: nil)
        spy.details[2] = SeerrServiceDetails(
            server: uhd,
            profiles: [SeerrQualityProfile(id: 19, name: "Any"), SeerrQualityProfile(id: 20, name: "UHD")],
            rootFolders: [SeerrRootFolder(id: 3, path: "/tv-4k", freeSpace: nil)],
            languageProfiles: nil, tags: nil)
        return spy
    }

    private func request(_ fields: String, type: String = "tv") -> SeerrRequest {
        let json = """
        {"id": 5, "status": 1, "type": "\(type)", "seasons": [
            {"id": 1, "seasonNumber": 1, "status": 1}, {"id": 2, "seasonNumber": 2, "status": 1}
        ]\(fields.isEmpty ? "" : ", " + fields)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(SeerrRequest.self, from: Data(json.utf8))
    }

    @Test func aSeasonOnlyEditSendsTheRequestUnchangedApartFromTheSeasons() async {
        let req = request(#""serverId": null, "profileId": null, "rootFolder": null, "languageProfileId": 3, "tags": [4, 5]"#)
        let model = SeerrRequestEditModel(request: req, configService: config())
        await model.bootstrap()
        model.selectedSeasons.remove(2)

        let body = model.buildUpdateBody()
        #expect(body == SeerrRequestUpdateBody(
            mediaType: .tv, serverId: nil, profileId: nil, rootFolder: nil,
            languageProfileId: 3, tags: [4, 5], seasons: [1]))
    }

    /// The pickers must open on what the request routes with, not on the first entry of the list.
    @Test func thePickersOpenOnTheRequestsOwnValues() async {
        let req = request(#""serverId": 1, "profileId": 11, "rootFolder": "/anime""#)
        let model = SeerrRequestEditModel(request: req, configService: config())
        await model.bootstrap()
        #expect(model.serverID == 1)
        #expect(model.profileID == 11)
        #expect(model.rootFolder == "/anime")
    }

    @Test func aProfileEditSendsTheNewProfileAndKeepsEverythingElse() async {
        let req = request(#""serverId": 1, "profileId": 10, "rootFolder": "/tv", "tags": []"#)
        let model = SeerrRequestEditModel(request: req, configService: config())
        await model.bootstrap()
        model.profileID = 11

        let body = model.buildUpdateBody()
        #expect(body.mediaType == .tv)
        #expect(body.serverId == 1)
        #expect(body.profileId == 11)
        #expect(body.rootFolder == "/tv")
        #expect(body.tags == [])
        #expect(body.seasons == [1, 2])
    }

    /// `media.serviceId` is the non-4K instance and nil until the media reached an arr; a 4K request that
    /// Seerr routes by default goes to the 4K default.
    @Test func a4KRequestWithoutAServerIsEditedAgainstThe4KDefault() async {
        let req = request(#""is4k": true, "media": {"id": 1, "serviceId": 1}"#)
        let model = SeerrRequestEditModel(request: req, configService: config())
        await model.bootstrap()
        #expect(model.serverID == 2)
        #expect(model.profileID == 20)
        #expect(model.buildUpdateBody().serverId == nil)
    }

    @Test func aServerChangeSendsTheNewServerAndDropsItsForeignIDs() async {
        let req = request(#""serverId": 1, "profileId": 10, "rootFolder": "/tv", "languageProfileId": 3, "tags": [4]"#)
        let model = SeerrRequestEditModel(request: req, configService: config())
        await model.bootstrap()
        await model.selectServer(2)

        let body = model.buildUpdateBody()
        #expect(body.serverId == 2)
        #expect(body.profileId == 20)
        #expect(body.rootFolder == "/tv-4k")
        #expect(body.languageProfileId == nil)
        #expect(body.tags == nil)
    }

    @Test func aMovieEditCarriesItsMediaTypeAndNoSeasons() async throws {
        let req = request(#""serverId": 1, "profileId": 10, "rootFolder": "/tv""#, type: "movie")
        let model = SeerrRequestEditModel(request: req, configService: config())
        await model.bootstrap()

        let data = try JSONEncoder().encode(model.buildUpdateBody())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["mediaType"] as? String == "movie")
        #expect(json["serverId"] as? Int == 1)
        #expect(json["seasons"] == nil)
    }

    /// CAT-203. With the server options failed to load, the pickers are empty and the body would clear the
    /// request's profile, folder and tags; Save must stay off.
    @Test func saveStaysOffWhenTheServerOptionsFailedToLoad() async {
        let spy = config()
        spy.details[1] = nil
        let req = request(#""serverId": 1, "profileId": 11, "rootFolder": "/anime", "tags": [4]"#)
        let model = SeerrRequestEditModel(request: req, configService: spy)
        await model.bootstrap()
        #expect(model.loadError != nil)
        #expect(model.isReady == false)
        #expect(model.updateBody == nil)

        spy.details[1] = config().details[1]
        await model.bootstrap()
        #expect(model.isReady)
        #expect(model.updateBody?.profileId == 11)
        #expect(model.updateBody?.tags == [4])
    }

    /// CAT-208. Cycle to server 2 and straight back to 1: the slow answer for 2 must not replace the lists.
    @Test func aSlowAnswerForAnEarlierServerDoesNotReplaceTheCurrentOnesLists() async {
        let spy = config()
        spy.delays[2] = .milliseconds(300)
        let req = request(#""serverId": 1, "profileId": 10, "rootFolder": "/tv""#)
        let model = SeerrRequestEditModel(request: req, configService: spy)
        await model.bootstrap()

        let slow = Task { await model.selectServer(2) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.selectServer(1)
        await slow.value

        #expect(model.serverID == 1)
        #expect(model.profiles.map(\.id) == [9, 10, 11])
        #expect(model.profileID == 10)
        #expect(model.rootFolder == "/tv")
        #expect(model.isReady)
    }
}
