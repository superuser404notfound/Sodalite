import Testing
import Foundation
@testable import Sodalite

/// The guide's channel filters are the one place where a wrong query name fails silently: the
/// server ignores an unknown parameter and returns everything, which reads as "the filter does
/// nothing" rather than as an error.
struct GuideFilterTests {

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first(where: { $0.name == name })?.value
    }

    /// Jellyfin drops `Type` on /LiveTv/Channels and answers the category flags from channel tags
    /// no channel carries (#201). Sending them changed nothing but the reader's expectations.
    @Test("the default filter sends nothing, kind and category are narrowed on the client")
    func defaultFilter() {
        #expect(GuideFilter.default.queryItems.isEmpty)
        #expect(GuideFilter.default.isDefault)
        var filter = GuideFilter.default
        filter.kind = .radio
        filter.category = .sports
        #expect(filter.queryItems.isEmpty)
    }

    /// The Live TV tab gate asks "does this server have channels at all". Narrowing that probe to
    /// TV would hide the whole tab from a server whose tuners are radio only.
    @Test("the any filter admits every kind")
    func anyFilter() {
        #expect(GuideFilter.any.queryItems.isEmpty)
        #expect(!GuideFilter.any.isDefault)
        #expect(GuideFilter.any.admits(kindOf: channel(type: "Radio")))
        #expect(GuideFilter.any.admits(kindOf: channel(type: "TV")))
    }

    @Test("favorites only adds IsFavorite")
    func favorites() {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        #expect(value(filter.queryItems, "IsFavorite") == "true")
        #expect(filter.queryItems.count == 1)
        #expect(!filter.isDefault)
    }

    @Test("each category maps to the program flag Jellyfin actually reads")
    func categoryNames() {
        #expect(GuideFilter.Category.sports.queryName == "IsSports")
        #expect(GuideFilter.Category.kids.queryName == "IsKids")
        #expect(GuideFilter.Category.news.queryName == "IsNews")
        #expect(GuideFilter.Category.movies.queryName == "IsMovie")
    }

    /// The M3U tuner never sets a type, and Jellyfin files such a channel as TV.
    @Test("kind follows ChannelType, a channel without one is TV")
    func kindNarrowing() {
        var filter = GuideFilter.default
        #expect(filter.admits(kindOf: channel(type: "TV")))
        #expect(filter.admits(kindOf: channel(type: nil)))
        #expect(!filter.admits(kindOf: channel(type: "Radio")))
        filter.kind = .radio
        #expect(filter.admits(kindOf: channel(type: "Radio")))
        #expect(!filter.admits(kindOf: channel(type: nil)))
    }

    @Test("ChannelType decodes off the channel list")
    func channelTypeDecodes() throws {
        let json = #"{"Id":"c1","Name":"Radio 1","ChannelType":"Radio"}"#
        let decoded = try JSONDecoder().decode(JellyfinChannel.self, from: Data(json.utf8))
        #expect(decoded.kind == .radio)
    }

    private func channel(type: String?) -> JellyfinChannel {
        JellyfinChannel(id: "c", name: "c", channelNumber: nil, imageTags: nil,
                        currentProgram: nil, userData: nil, channelType: type)
    }

    @Test("the endpoint merges filter items into the channel query")
    func endpointMergesFilter() {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        let endpoint = JellyfinEndpoint.liveTvChannels(
            userID: "u1", startIndex: 0, limit: 200, filter: filter)
        let items = endpoint.queryItems ?? []
        #expect(value(items, "IsFavorite") == "true")
        #expect(value(items, "Type") == nil)
        // The base items the guide has always relied on must survive the merge.
        #expect(value(items, "AddCurrentProgram") == "true")
        #expect(value(items, "EnableFavoriteSorting") == "true")
        #expect(value(items, "EnableUserData") == "true")
        #expect(value(items, "Limit") == "200")
        #expect(value(items, "StartIndex") == "0")
        #expect(value(items, "UserId") == "u1")
    }
}
