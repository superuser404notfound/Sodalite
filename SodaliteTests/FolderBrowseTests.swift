import Foundation
import Testing
@testable import Sodalite

/// Sodalite#180. A home-video library (a Pinchflat YouTube folder in the report) holds nothing the
/// server types as Movie or Series, so the My Media tile's type query came back empty. It is walked
/// as a folder tree instead, one non-recursive level per grid, and these pin that query shape.
struct FolderBrowseTests {
    private let service = JellyfinImageService(baseURLProvider: { URL(string: "https://jf.test") })

    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func value(_ name: String, in query: ItemQuery) -> String? {
        query.toQueryItems().first { $0.name == name }?.value
    }

    @Test func onlyHomeVideoLibrariesBrowseByFolder() {
        #expect(MyMediaLibraries.browsesFolders(.homevideos))
        #expect(!MyMediaLibraries.browsesFolders(.movies))
        #expect(!MyMediaLibraries.browsesFolders(.tvshows))
        #expect(!MyMediaLibraries.browsesFolders(.boxsets))
        #expect(!MyMediaLibraries.browsesFolders(.unknown))
    }

    /// The load-bearing half: a recursive query flattens every channel into one list, and a type
    /// query without Folder hides the channels.
    @Test func aFolderLevelAsksForItsDirectFoldersAndVideos() {
        let query = MyMediaLibraries.folderQuery(parentID: "lib1")
        #expect(value("ParentId", in: query) == "lib1")
        #expect(value("Recursive", in: query) == "false")
        #expect(value("IncludeItemTypes", in: query) == "Folder,Video")
    }

    @Test func everyOtherQueryStaysRecursive() {
        let query = ItemQuery(parentID: "lib1", includeItemTypes: [.movie], fields: "")
        #expect(value("Recursive", in: query) == "true")
    }

    @Test func aVideoDecodesToItsOwnType() throws {
        let video = try item(#"{"Id":"v1","Name":"Clip","Type":"Video"}"#)
        #expect(video.type == .video)
    }

    /// A folder's primary is usually a channel avatar, which a 16:9 card would crop to a sliver.
    @Test func aFolderCardPrefersWideArtOverItsPrimary() throws {
        let folder = try item(
            #"{"Id":"f1","Name":"Channel","Type":"Folder","ImageTags":{"Primary":"p1"},"BackdropImageTags":["b1"]}"#
        )
        let url = try #require(service.folderBrowseArtworkURL(for: folder))
        #expect(url.path == "/Items/f1/Images/Backdrop")
    }

    @Test func aFolderWithOnlyAPrimaryStillGetsIt() throws {
        let folder = try item(#"{"Id":"f1","Name":"Channel","Type":"Folder","ImageTags":{"Primary":"p1"}}"#)
        let url = try #require(service.folderBrowseArtworkURL(for: folder))
        #expect(url.path == "/Items/f1/Images/Primary")
    }

    @Test func aVideoCardUsesItsOwnStill() throws {
        let video = try item(
            #"{"Id":"v1","Name":"Clip","Type":"Video","ImageTags":{"Primary":"p1"},"BackdropImageTags":["b1"]}"#
        )
        let url = try #require(service.folderBrowseArtworkURL(for: video))
        #expect(url.path == "/Items/v1/Images/Primary")
    }

    /// Wide cards keep the poster grid's card-to-column proportion on every tier.
    @Test func aWideCardGridScalesItsColumnLikeThePosterGrid() {
        for metrics in [LayoutMetrics.tv, .regular, .compact] {
            let poster = metrics.gridColumnMinimum(cardScale: 1)
            let wide = metrics.gridColumnMinimum(for: .landscape, cardScale: 1)
            #expect(abs(wide / poster - metrics.landscapeSize.width / metrics.posterSize.width) < 0.0001)
            #expect(metrics.gridColumnMinimum(for: .poster, cardScale: 1.3) == metrics.gridColumnMinimum(cardScale: 1.3))
        }
    }
}
