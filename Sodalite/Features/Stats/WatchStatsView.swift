import SwiftUI

struct WatchStatsView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var viewModel: WatchStatsViewModel?
    @State private var selectedItem: JellyfinItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("stats.title")
                    .font(.title2)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                content
            }
            .screenContentInset()
        }
        .detailDestination(item: $selectedItem) { item in
            DetailRouterView(item: item)
        }
        .task {
            guard let userID = appState.activeUser?.id else { return }
            let vm: WatchStatsViewModel
            if let existing = viewModel {
                vm = existing
            } else {
                vm = WatchStatsViewModel(
                    libraryService: dependencies.jellyfinLibraryService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID
                )
                viewModel = vm
            }
            // A cancel mid-scan (tvOS keeps this view's @State alive across a tab switch but still
            // cancels and re-fires .task) leaves stats nil with no error, sticking the spinner
            // forever on return. Rerun on the same view model instead of the one-shot guard this
            // used to be (Audit 2026-09-25 DIAG-4).
            guard vm.stats == nil, vm.errorMessage == nil else { return }
            await vm.loadStats()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel, let stats = vm.stats {
            if stats.isEmpty {
                emptyState
            } else {
                statsContent(vm: vm, stats: stats)
            }
        } else if let message = viewModel?.errorMessage {
            errorState(message: message)
        } else {
            loadingState
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 20) {
            ProgressView()
            if let count = viewModel?.progressCount, count > 0 {
                Text("stats.scanProgress \(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("stats.empty")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 20) {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            Button("stats.error.retry") {
                Task { await viewModel?.loadStats() }
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Content

    private func statsContent(vm: WatchStatsViewModel, stats: WatchStats) -> some View {
        VStack(alignment: .leading, spacing: 48) {
            watchTimeHeadline(stats)
            countGrid(stats)
            if !stats.topGenres.isEmpty { topGenres(stats) }
            if !stats.mostRewatched.isEmpty {
                itemRail(title: "stats.mostRewatched", items: stats.mostRewatched, vm: vm)
            }
            if !stats.recentlyWatched.isEmpty {
                itemRail(title: "stats.recentlyWatched", items: stats.recentlyWatched, vm: vm)
            }
        }
    }

    private func watchTimeHeadline(_ stats: WatchStats) -> some View {
        VStack(spacing: 8) {
            Text("stats.watchTime.value \(stats.estimatedHours)")
                .font(.system(size: hSizeClass == .compact ? 30 : 48, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("stats.watchTime.days \(stats.estimatedDays.formatted(.number.precision(.fractionLength(1))))")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("stats.watchTime.approxNote")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if stats.scanCapped {
                Text("stats.scanCapped \(stats.scannedItemCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func countGrid(_ stats: WatchStats) -> some View {
        let columns = Array(repeating: GridItem(.flexible()), count: hSizeClass == .compact ? 2 : 4)
        let completion = (stats.completionRate * 100).formatted(.number.precision(.fractionLength(0)))
        return LazyVGrid(columns: columns, spacing: 16) {
            StatTile(icon: "film", value: "\(stats.moviesWatched)", label: "stats.movies")
            StatTile(icon: "tv", value: "\(stats.episodesWatched)", label: "stats.episodes")
            StatTile(icon: "rectangle.stack", value: "\(stats.seriesStarted)", label: "stats.seriesStarted")
            StatTile(icon: "checkmark.seal", value: "\(completion)%", label: "stats.completion")
        }
    }

    private func topGenres(_ stats: WatchStats) -> some View {
        let maxCount = max(1, stats.topGenres.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 16) {
            Text("stats.topGenres")
                .font(.title3).fontWeight(.semibold)
            VStack(spacing: 14) {
                ForEach(stats.topGenres) { genre in
                    GenreBar(
                        name: genre.name,
                        count: genre.count,
                        fraction: Double(genre.count) / Double(maxCount)
                    )
                }
            }
        }
    }

    private func itemRail(title: LocalizedStringKey, items: [JellyfinItem], vm: WatchStatsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3).fontWeight(.semibold)
            VStack(spacing: 12) {
                ForEach(items) { item in
                    CollectionItemRow(
                        item: item,
                        imageURL: vm.imageService.posterURL(for: item, maxWidth: ImageWidth.thumbnail),
                        onSelect: { selectedItem = item }
                    )
                }
            }
        }
    }
}
