import SwiftUI

/// What the rung dialog needs to estimate sizes: the source's bitrate and size, and the runtime.
struct DownloadFacts: Equatable {
    let bitrate: Int?
    let size: Int64?
    let runtimeTicks: Int64?

    static func of(_ item: JellyfinItem, sourceID: String?, order: VersionOrder) -> DownloadFacts {
        let source = item.effectiveMediaSource(id: sourceID ?? VersionSelection(order: order).preferredSourceID(for: item))
        return DownloadFacts(bitrate: source?.bitrate, size: source?.size, runtimeTicks: item.runTimeTicks)
    }

    /// A season is an estimate over its episodes: the highest bitrate decides which rungs bite, sizes
    /// and runtimes add up, and one unknown size makes the original's total unknown.
    static func of(season episodes: [JellyfinItem], order: VersionOrder) -> DownloadFacts {
        let selection = VersionSelection(order: order)
        let sources = episodes.map { $0.effectiveMediaSource(id: selection.preferredSourceID(for: $0)) }
        let sizes = sources.map { $0?.size }
        return DownloadFacts(
            bitrate: sources.compactMap { $0?.bitrate }.max(),
            size: sizes.contains(where: { $0 == nil }) ? nil : sizes.compactMap { $0 }.reduce(0, +),
            runtimeTicks: episodes.compactMap(\.runTimeTicks).reduce(0, +))
    }
}

/// One movie or episode, or a whole season (Sodalite#81). `sourceID` is the version the page has
/// selected, nil where there is no choice; the dialog downloads exactly that one (Sodalite#200).
enum DownloadTarget: Identifiable {
    case item(JellyfinItem, sourceID: String?)
    /// `serverID` is the series' server in a combined Home (Sodalite#202).
    case season(seriesID: String, seasonID: String, episodes: [JellyfinItem], serverID: String?)

    var id: String {
        switch self {
        case .item(let item, _): item.id
        case .season(_, let seasonID, _, _): "season-\(seasonID)"
        }
    }

    func facts(order: VersionOrder) -> DownloadFacts {
        switch self {
        case .item(let item, let sourceID): .of(item, sourceID: sourceID, order: order)
        case .season(_, _, let episodes, _): .of(season: episodes, order: order)
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

#if !os(tvOS)
/// Asks which rung to download at, every time, best first (Sodalite#81).
private struct DownloadRungDialog: ViewModifier {
    @Binding var target: DownloadTarget?
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState
    @Environment(\.serverSession) private var serverSession
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
                    Button(label(for: option)) { start(target, option: option) }
                }
                Button("common.cancel", role: .cancel) {}
            } message: { target in
                let message = message(for: target)
                if !message.isEmpty { Text(message) }
            }
            .alert(errorMessage ?? "", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("common.ok") {}
            }
    }

    private func options(for target: DownloadTarget) -> [DownloadRungOption] {
        let facts = target.facts(order: dependencies.playbackPreferences.versionOrder)
        return DownloadRungOption.options(sourceBitrate: facts.bitrate, sourceSize: facts.size,
                                          runtimeTicks: facts.runtimeTicks,
                                          canTranscodeVideo: appState.canTranscodeVideo(on: serverSession))
    }

    /// The version the page has selected, the one Play would start. Listing every version here as
    /// well left the smaller rungs without a version to read (Sodalite#200 follow-up, AJPerez).
    private func selectedVersion(for target: DownloadTarget) -> MediaSource? {
        guard case .item(let item, let sourceID) = target else { return nil }
        let order = dependencies.playbackPreferences.versionOrder
        return item.effectiveMediaSource(id: sourceID ?? VersionSelection(order: order).preferredSourceID(for: item))
    }

    private func message(for target: DownloadTarget) -> String {
        var lines: [String] = []
        if case .item(let item, _) = target, item.selectableMediaSources.count > 1,
           let version = selectedVersion(for: target)?.versionLabel(includingSize: false), !version.isEmpty {
            lines.append(String(localized: "downloads.dialog.version \(version)"))
        }
        if options(for: target).contains(where: { $0.quality != .original }) {
            lines.append(String(localized: "downloads.dialog.transcodeNote"))
        }
        return lines.joined(separator: "\n\n")
    }

    private func label(for option: DownloadRungOption) -> String {
        let title = String(localized: String.LocalizationValue(option.quality.titleKey))
        let size = option.estimatedBytes.map { $0.formatted(.byteCount(style: .file)) }
            ?? String(localized: "downloads.dialog.sizeUnknown", defaultValue: "size unknown")
        return "\(title) · \(size)"
    }

    private func start(_ target: DownloadTarget, option: DownloadRungOption) {
        guard let manager = dependencies.downloadManager else { return }
        Task {
            do {
                switch target {
                case .item(let item, let sourceID):
                    try await manager.enqueue(item: item, quality: option.quality,
                                              mediaSourceID: selectedVersion(for: target)?.id ?? sourceID)
                case .season(let seriesID, let seasonID, _, let serverID):
                    try await manager.enqueueSeason(seriesID: seriesID, seasonID: seasonID, serverID: serverID, quality: option.quality)
                }
                dependencies.beginDownloadActivity()
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
        #if !os(tvOS)
        modifier(DownloadRungDialog(target: target))
        #else
        self
        #endif
    }
}

#if !os(tvOS)

/// The download control of a detail page: starts, shows progress, and offers pause, retry and removal.
struct DownloadActionButton: View {
    let item: JellyfinItem
    /// The version the page has selected, carried into the dialog (Sodalite#200).
    var sourceID: String? = nil
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
                case .available: target = .item(item, sourceID: sourceID)
                case .paused:
                    manager.resume(itemID: item.id)
                    dependencies.beginDownloadActivity()
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
/// Pause, resume or retry: what a download in progress does besides cancelling.
@MainActor
struct DownloadPrimaryAction {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let perform: () -> Void

    init?(itemID: String, state: DownloadButtonState, manager: DownloadManager, dependencies: DependencyContainer) {
        switch state {
        case .queued, .downloading:
            titleKey = "downloads.action.pause"
            systemImage = "pause.circle"
            perform = { Task { await manager.pause(itemID: itemID) } }
        case .paused:
            titleKey = "downloads.action.resume"
            systemImage = "play.circle"
            perform = {
                manager.resume(itemID: itemID)
                dependencies.beginDownloadActivity()
            }
        case .failed:
            titleKey = "downloads.action.retry"
            systemImage = "arrow.clockwise.circle"
            perform = {
                manager.retry(itemID: itemID)
                dependencies.beginDownloadActivity()
            }
        case .available, .downloaded:
            return nil
        }
    }
}

struct DownloadMenuActions: View {
    let itemID: String
    let state: DownloadButtonState
    let manager: DownloadManager
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        if let primary = DownloadPrimaryAction(itemID: itemID, state: state, manager: manager, dependencies: dependencies) {
            Button(primary.titleKey, action: primary.perform)
        }
        Button(state == .downloaded ? "downloads.action.remove" : "downloads.action.cancel", role: .destructive) {
            Task { await manager.cancel(itemID: itemID) }
        }
    }
}
#endif
