import SwiftUI

/// What the rung dialog needs to estimate sizes: the source's bitrate and size, and the runtime.
struct DownloadFacts: Equatable {
    let bitrate: Int?
    let size: Int64?
    let runtimeTicks: Int64?

    static func of(_ item: JellyfinItem) -> DownloadFacts {
        let source = item.mediaSources?.first
        return DownloadFacts(bitrate: source?.bitrate, size: source?.size, runtimeTicks: item.runTimeTicks)
    }

    /// A season is an estimate over its episodes: the highest bitrate decides which rungs bite, sizes
    /// and runtimes add up, and one unknown size makes the original's total unknown.
    static func of(season episodes: [JellyfinItem]) -> DownloadFacts {
        let sources = episodes.map { $0.mediaSources?.first }
        let sizes = sources.map { $0?.size }
        return DownloadFacts(
            bitrate: sources.compactMap { $0?.bitrate }.max(),
            size: sizes.contains(where: { $0 == nil }) ? nil : sizes.compactMap { $0 }.reduce(0, +),
            runtimeTicks: episodes.compactMap(\.runTimeTicks).reduce(0, +))
    }
}

/// One movie or episode, or a whole season (Sodalite#81).
enum DownloadTarget: Identifiable {
    case item(JellyfinItem)
    case season(seriesID: String, seasonID: String, episodes: [JellyfinItem])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .season(_, let seasonID, _): "season-\(seasonID)"
        }
    }

    var facts: DownloadFacts {
        switch self {
        case .item(let item): .of(item)
        case .season(_, _, let episodes): .of(season: episodes)
        }
    }
}

extension DownloadFailure {
    var message: String {
        switch self {
        case .notAllowed:
            String(localized: "downloads.error.notAllowed", defaultValue: "This server does not allow downloads for this user.")
        case .unauthorized:
            String(localized: "downloads.error.unauthorized", defaultValue: "The sign-in expired. Retry to continue.")
        case .noSpace:
            String(localized: "downloads.error.noSpace", defaultValue: "Not enough free space for this download.")
        case .network:
            String(localized: "downloads.error.network", defaultValue: "The download was interrupted.")
        case .server:
            String(localized: "downloads.error.server", defaultValue: "The server could not provide this download.")
        }
    }
}

#if os(iOS)
/// Asks which rung to download at, every time, with the last one used on top (Sodalite#81).
private struct DownloadRungDialog: ViewModifier {
    @Binding var target: DownloadTarget?
    @Environment(\.dependencies) private var dependencies
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "downloads.dialog.title",
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                titleVisibility: .visible,
                presenting: target
            ) { target in
                ForEach(options(for: target)) { option in
                    Button(label(for: option)) { start(target, quality: option.quality) }
                }
                Button("common.cancel", role: .cancel) {}
            } message: { target in
                if options(for: target).contains(where: { $0.quality != .original }) {
                    Text("downloads.dialog.transcodeNote")
                }
            }
            .alert(errorMessage ?? "", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("common.ok") {}
            }
    }

    private func options(for target: DownloadTarget) -> [DownloadRungOption] {
        let facts = target.facts
        return DownloadRungOption.options(sourceBitrate: facts.bitrate, sourceSize: facts.size,
                                          runtimeTicks: facts.runtimeTicks,
                                          lastUsed: dependencies.downloadPreferences.lastQuality)
    }

    private func label(for option: DownloadRungOption) -> String {
        let title = String(localized: String.LocalizationValue(option.quality.titleKey))
        let size = option.estimatedBytes.map { $0.formatted(.byteCount(style: .file)) }
            ?? String(localized: "downloads.dialog.sizeUnknown", defaultValue: "size unknown")
        return "\(title) · \(size)"
    }

    private func start(_ target: DownloadTarget, quality: StreamingQuality) {
        guard let manager = dependencies.downloadManager else { return }
        dependencies.downloadPreferences.lastQuality = quality
        Task {
            do {
                switch target {
                case .item(let item):
                    try await manager.enqueue(item: item, quality: quality)
                case .season(let seriesID, let seasonID, _):
                    try await manager.enqueueSeason(seriesID: seriesID, seasonID: seasonID, quality: quality)
                }
            } catch {
                errorMessage = ErrorText.user(for: error)
            }
        }
    }
}

#endif

extension View {
    /// No-op on tvOS, where nothing downloads.
    @ViewBuilder
    func downloadRungDialog(target: Binding<DownloadTarget?>) -> some View {
        #if os(iOS)
        modifier(DownloadRungDialog(target: target))
        #else
        self
        #endif
    }
}

#if os(iOS)

/// The download control of a detail page: starts, shows progress, and offers pause, retry and removal.
struct DownloadActionButton: View {
    let item: JellyfinItem
    @Binding var target: DownloadTarget?
    @Environment(\.dependencies) private var dependencies
    @State private var showsMenu = false

    var body: some View {
        if let manager = dependencies.downloadManager {
            let downloaded = dependencies.downloadStore.item(item.id)
            let state = DownloadButtonState.from(downloaded, liveProgress: manager.liveProgress[item.id])
            GlassActionButton(
                title: LocalizedStringKey(state.titleKey),
                systemImage: state.systemImage,
                progressFraction: state.progressFraction
            ) {
                switch state {
                case .available: target = .item(item)
                case .paused: manager.resume(itemID: item.id)
                default: showsMenu = true
                }
            }
            .confirmationDialog("", isPresented: $showsMenu, titleVisibility: .hidden) {
                DownloadMenuActions(itemID: item.id, state: state, manager: manager)
            } message: {
                if let failure = downloaded?.manifest.failure, state == .failed { Text(failure.message) }
            }
        }
    }
}

/// The actions every place that shows a download offers for it.
struct DownloadMenuActions: View {
    let itemID: String
    let state: DownloadButtonState
    let manager: DownloadManager

    var body: some View {
        switch state {
        case .downloading:
            Button("downloads.action.pause") { Task { await manager.pause(itemID: itemID) } }
        case .paused:
            Button("downloads.action.resume") { manager.resume(itemID: itemID) }
        case .failed:
            Button("downloads.action.retry") { manager.retry(itemID: itemID) }
        default:
            EmptyView()
        }
        Button(state == .downloaded ? "downloads.action.remove" : "downloads.action.cancel", role: .destructive) {
            Task { await manager.cancel(itemID: itemID) }
        }
    }
}
#endif
