import Foundation
import Testing
@testable import Sodalite

@MainActor
struct LibraryLayoutHomeTests {
    private func vm() -> HomeViewModel {
        let lib = HomeSourceRowTests.RecordingLibrary()
        return HomeViewModel(
            libraryService: lib,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u", serverID: "a-\(UUID().uuidString)")
    }

    private func library(_ id: String, server: String, type: String = "movies") -> JellyfinLibrary {
        var l = JellyfinLibrary(id: id, name: id, collectionType: type, imageTags: nil)
        l.serverID = server
        return l
    }

    @Test func myMediaFollowsTheLayout() {
        let model = vm()
        let libs = [library("1", server: "a"), library("2", server: "a"), library("3", server: "a")]
        model.libraryLayout = LibraryLayout(entries: [.init(serverID: "a", libraryID: "3", isHidden: false),
                                                      .init(serverID: "a", libraryID: "2", isHidden: true)])
        #expect(model.myMediaVisible(libs).map(\.id) == ["3", "1"])
    }

    @Test func aHiddenLibrarysLatestRowIsNotPlanned() {
        let model = vm()
        model.libraryLayout = LibraryLayout(entries: [.init(serverID: "a", libraryID: "2", isHidden: true)])
        let configs = [
            HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 0, libraryID: "1", libraryName: "1", collectionType: "movies"),
            HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 1, libraryID: "2", libraryName: "2", collectionType: "movies"),
        ]
        #expect(model.plannedRows(from: configs).map(\.id) == ["libraryLatest:1"])
    }
}
