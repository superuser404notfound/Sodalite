import Foundation

enum DownloadsGrouping {
    struct Season: Identifiable {
        let id: String
        let name: String
        let number: Int?
        let episodes: [DownloadedItem]
    }

    struct Series: Identifiable {
        let id: String
        let name: String
        let seasons: [Season]
    }

    static func group(_ items: [DownloadedItem]) -> (active: [DownloadedItem], movies: [DownloadedItem], series: [Series]) {
        let finished: (DownloadedItem) -> Bool = { $0.manifest.state == .complete || $0.manifest.state == .missingOnServer }
        let active = items.filter { !finished($0) }.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
        let done = items.filter(finished)
        let movies = done.filter { $0.snapshot.item.seriesId == nil }
            .sorted { $0.snapshot.item.name.localizedStandardCompare($1.snapshot.item.name) == .orderedAscending }
        let bySeries = Dictionary(grouping: done.filter { $0.snapshot.item.seriesId != nil }) { $0.snapshot.item.seriesId! }
        let series = bySeries.map { seriesID, episodes -> Series in
            let bySeason = Dictionary(grouping: episodes) { $0.snapshot.item.parentIndexNumber ?? 0 }
            let seasons = bySeason.keys.sorted().map { number -> Season in
                let eps = bySeason[number]!.sorted { ($0.snapshot.item.indexNumber ?? 0) < ($1.snapshot.item.indexNumber ?? 0) }
                return Season(id: "\(seriesID)-\(number)", name: eps.first?.snapshot.season?.name ?? "", number: number, episodes: eps)
            }
            let name = episodes.first?.snapshot.series?.name ?? episodes.first?.snapshot.item.seriesName ?? ""
            return Series(id: seriesID, name: name, seasons: seasons)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (active, movies, series)
    }
}
