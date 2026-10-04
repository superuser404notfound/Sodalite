import Foundation
import Testing
@testable import Sodalite

@MainActor
struct CombinedHomeViewModelTests {
    private func vm() -> HomeViewModel {
        let lib = HomeSourceRowTests.RecordingLibrary()
        let sources = [
            HomeSource(serverID: "a", serverName: "Wohnzimmer", userID: "u", libraryService: lib, isActive: true),
            HomeSource(serverID: "b", serverName: "Keller", userID: "u", libraryService: lib, isActive: false),
        ]
        let model = HomeViewModel(
            libraryService: lib,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u", serverID: "a-\(UUID().uuidString)", sources: sources)
        return model
    }

    private func library(_ id: String, _ name: String, server: String) -> JellyfinLibrary {
        var l = JellyfinLibrary(id: id, name: name, collectionType: "movies", imageTags: nil)
        l.serverID = server
        return l
    }

    @Test func serverLabelOnlyOnDuplicateNames() {
        let model = vm()
        model.myMediaLibraries = [library("1", "Movies", server: "a"), library("2", "Movies", server: "b"), library("3", "Shows", server: "b")]
        #expect(model.serverLabel(forLibrary: model.myMediaLibraries[0]) == "Wohnzimmer")
        #expect(model.serverLabel(forLibrary: model.myMediaLibraries[1]) == "Keller")
        #expect(model.serverLabel(forLibrary: model.myMediaLibraries[2]) == nil)
    }

    @Test func singleServerNeverLabels() {
        let lib = HomeSourceRowTests.RecordingLibrary()
        let model = HomeViewModel(
            libraryService: lib,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u", serverID: "a-\(UUID().uuidString)")
        model.myMediaLibraries = [library("1", "Movies", server: "a"), library("2", "Movies", server: "a")]
        #expect(model.serverLabel(forLibrary: model.myMediaLibraries[0]) == nil)
    }

    @Test func thumbArtworkFollowsTheItemsServer() throws {
        let lib = HomeSourceRowTests.RecordingLibrary()
        let model = HomeViewModel(
            libraryService: lib,
            imageService: JellyfinImageService(endpoint: { $0 == "b" ? (URL(string: "http://b.lan")!, "t") : (URL(string: "http://a.lan")!, "t") }),
            userID: "u", serverID: "a")
        let episode = try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"e","Name":"e","Type":"Episode","SeriesId":"s","ServerId":"b"}"#.utf8))
        let url = model.imageURL(for: episode, rowType: .continueWatching, cwImage: .thumb)
        #expect(url?.host == "b.lan")
    }
}
