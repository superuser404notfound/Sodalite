#if os(iOS)
import SwiftUI

/// The Downloads tab (Sodalite#81). Reads only the store, so it works with no server at all.
struct DownloadsView: View {
    @Environment(\.dependencies) private var dependencies
    /// Set when the view is a sheet (compact iPhone, opened from the button beside the gear).
    var onClose: (() -> Void)? = nil
    @State private var confirmsDeleteAll = false
    /// Measured off the render path: a directory walk per body pass would run on every progress tick.
    @State private var usageText = ""

    private var store: DownloadStore { dependencies.downloadStore }

    var body: some View {
        ThemeNavigationStack {
            let groups = DownloadsGrouping.group(Array(store.items.values))
            List {
                if !groups.active.isEmpty {
                    Section("downloads.section.active") {
                        ForEach(groups.active) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
                if !groups.movies.isEmpty {
                    Section("downloads.section.movies") {
                        ForEach(groups.movies) { item in
                            NavigationLink {
                                OfflineDetailView(item: item).themedNavigationDestination()
                            } label: {
                                DownloadRow(item: item)
                            }
                            .swipeActions { deleteButton(ids: [item.id]) }
                        }
                    }
                }
                if !groups.series.isEmpty {
                    Section("downloads.section.series") {
                        ForEach(groups.series) { series in
                            NavigationLink {
                                DownloadedSeriesView(seriesID: series.id).themedNavigationDestination()
                            } label: {
                                SeriesRow(series: series)
                            }
                            .swipeActions { deleteButton(ids: series.seasons.flatMap(\.episodes).map(\.id)) }
                        }
                    }
                }
                if store.items.isEmpty {
                    Text("downloads.empty")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        Button("downloads.deleteAll", role: .destructive) { confirmsDeleteAll = true }
                    } footer: {
                        Text("downloads.footer.usage \(usageText)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("tab.downloads")
            .task(id: usageKey) { measureUsage() }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close, action: onClose)
                    }
                }
            }
            .alert("downloads.deleteAll.confirm.title", isPresented: $confirmsDeleteAll) {
                Button("downloads.deleteAll", role: .destructive) { Task { await deleteAll() } }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("downloads.deleteAll.confirm.body \(store.items.count) \(usageText)")
            }
        }
    }

    /// Changes when an item arrives, leaves or finishes, not on progress.
    private var usageKey: String {
        store.items.values.map { "\($0.id):\($0.manifest.state.rawValue)" }.sorted().joined(separator: ",")
    }

    private func measureUsage() {
        guard let profile = store.activeProfile else { usageText = ""; return }
        usageText = store.usage(serverID: profile.serverID, userID: profile.userID).bytes.formatted(.byteCount(style: .file))
    }

    private func deleteButton(ids: [String]) -> some View {
        Button(role: .destructive) {
            Task { for id in ids { await dependencies.downloadManager?.cancel(itemID: id) } }
        } label: {
            Label("downloads.action.remove", systemImage: "trash")
        }
    }

    private func deleteAll() async {
        guard let profile = store.activeProfile else { return }
        await DownloadCleanup.perform(.profile(serverID: profile.serverID, userID: profile.userID),
                                      store: store, manager: dependencies.downloadManager)
    }
}

/// One download: artwork, title, rung, size and state.
struct DownloadRow: View {
    let item: DownloadedItem
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        let state = DownloadButtonState.from(item, liveProgress: dependencies.downloadManager?.liveProgress[item.id])
        HStack(spacing: 12) {
            LocalArtwork(url: item.artworkURL(.thumb) ?? item.artworkURL(.poster))
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).lineLimit(2)
                Text(caption(state: state)).font(.caption).foregroundStyle(.secondary)
                if case .downloading(let fraction) = state {
                    ProgressView(value: fraction ?? 0)
                }
                if item.manifest.state == .missingOnServer {
                    Text("downloads.missingOnServer").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.manifest.progress.played {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .contextMenu {
            if let manager = dependencies.downloadManager {
                DownloadMenuActions(itemID: item.id, state: state, manager: manager)
            }
        }
    }

    private var title: String {
        let snapshot = item.snapshot.item
        guard snapshot.seriesId != nil, let index = snapshot.indexNumber else { return snapshot.name }
        return "\(index). \(snapshot.name)"
    }

    private func caption(state: DownloadButtonState) -> String {
        let quality = item.manifest.quality.shortLabel
        switch state {
        case .downloaded:
            return "\(quality) · \(item.manifest.receivedBytes.formatted(.byteCount(style: .file)))"
        case .failed:
            return item.manifest.failure?.message ?? String(localized: String.LocalizationValue(state.titleKey))
        default:
            return "\(quality) · \(String(localized: String.LocalizationValue(state.titleKey)))"
        }
    }
}

private struct SeriesRow: View {
    let series: DownloadsGrouping.Series

    var body: some View {
        let episodes = series.seasons.flatMap(\.episodes)
        HStack(spacing: 12) {
            LocalArtwork(url: episodes.first?.artworkURL(.seriesPoster) ?? episodes.first?.artworkURL(.poster))
                .frame(width: 54, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(series.name).font(.body)
                Text(episodes.map(\.manifest.receivedBytes).reduce(0, +).formatted(.byteCount(style: .file)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A downloaded image, read off the disk once and kept: rows re-render on every progress tick.
struct LocalArtwork: View {
    let url: URL?

    private static let cache = NSCache<NSURL, UIImage>()

    private static func image(at url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    var body: some View {
        if let url, let image = Self.image(at: url) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.Theme.restFill)
        }
    }
}
#endif
