import Foundation
import Testing
@testable import Sodalite

@MainActor
struct DownloadsGroupingTests {
    private func d(_ id: String, type: String, series: String? = nil, season: Int? = nil, index: Int? = nil,
                   name: String = "x", state: DownloadState = .complete) -> DownloadedItem {
        var fields = #""Id":"\#(id)","Name":"\#(name)","Type":"\#(type)""#
        if let series { fields += #","SeriesId":"\#(series)","SeriesName":"Show \#(series)","SeasonId":"\#(series)-\#(season ?? 0)""# }
        if let season { fields += #","ParentIndexNumber":\#(season)"# }
        if let index { fields += #","IndexNumber":\#(index)"# }
        let item = try! JSONDecoder().decode(JellyfinItem.self, from: Data("{\(fields)}".utf8))
        let src = try! JSONDecoder().decode(PlaybackMediaSource.self, from: Data(#"{"Id":"s"}"#.utf8))
        var m = DownloadManifest(itemID: id, seriesID: series, seasonID: series.map { "\($0)-\(season ?? 0)" }, quality: .original,
                                 route: .original, mediaSourceID: "s", audioStreamIndex: nil, playSessionID: nil, state: .queued, createdAt: Date())
        if state != .queued { m.transition(to: .downloading) }
        if state == .complete { m.transition(to: .complete) }
        return DownloadedItem(manifest: m, snapshot: DownloadSnapshot(item: item, series: nil, season: nil, source: src), directory: URL(fileURLWithPath: "/x"))
    }

    @Test func splitsActiveMoviesAndSeries() {
        let result = DownloadsGrouping.group([
            d("m2", type: "Movie", name: "B"), d("m1", type: "Movie", name: "A"),
            d("e2", type: "Episode", series: "s", season: 1, index: 2),
            d("e1", type: "Episode", series: "s", season: 1, index: 1),
            d("e3", type: "Episode", series: "s", season: 2, index: 1),
            d("run", type: "Movie", state: .downloading),
        ])
        #expect(result.active.map(\.id) == ["run"])
        #expect(result.movies.map(\.id) == ["m1", "m2"])
        #expect(result.series.count == 1)
        #expect(result.series[0].seasons.map(\.number) == [1, 2])
        #expect(result.series[0].seasons[0].episodes.map(\.id) == ["e1", "e2"])
    }
}

