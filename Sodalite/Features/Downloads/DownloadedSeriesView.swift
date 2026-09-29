#if os(iOS)
import SwiftUI

/// One downloaded show, season by season (Sodalite#81).
struct DownloadedSeriesView: View {
    let seriesID: String
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        let series = DownloadsGrouping.group(Array(dependencies.downloadStore.items.values)).series.first { $0.id == seriesID }
        List {
            ForEach(series?.seasons ?? []) { season in
                Section {
                    ForEach(season.episodes) { episode in
                        NavigationLink {
                            OfflineDetailView(item: episode).themedNavigationDestination()
                        } label: {
                            DownloadRow(item: episode)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await dependencies.downloadManager?.cancel(itemID: episode.id) }
                            } label: {
                                Label("downloads.action.remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(verbatim: season.name.isEmpty ? "S\(season.number ?? 0)" : season.name)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(series?.name ?? "")
    }
}
#endif
