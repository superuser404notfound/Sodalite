import SwiftUI
import Observation

@Observable
@MainActor
final class RecordingsViewModel {
    private(set) var recordings: [JellyfinItem] = []
    private(set) var timers: [LiveTvTimer] = []
    private(set) var seriesTimers: [LiveTvSeriesTimer] = []
    /// Ids the server reports currently being written (IsInProgress=true). Drives the "Läuft" badge;
    /// item fields can't (BaseItemDto.Status stays empty on recording items).
    private(set) var inProgressIDs: Set<String> = []
    private(set) var isLoading = false
    var errorMessage: String?

    func isInProgress(_ item: JellyfinItem) -> Bool {
        inProgressIDs.contains(item.id)
    }

    private let liveTvService: JellyfinLiveTvServiceProtocol
    private let itemService: JellyfinItemServiceProtocol
    private let userID: String

    init(liveTvService: JellyfinLiveTvServiceProtocol,
         itemService: JellyfinItemServiceProtocol,
         userID: String) {
        self.liveTvService = liveTvService
        self.itemService = itemService
        self.userID = userID
    }

    /// Fetch all three sections concurrently; errors degrade per section (empty timers == failed by
    /// design; only a recordings failure surfaces the alert).
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        // Owned by the model, not by the view's task: leaving the segment mid-load cancelled the
        // requests, and the cancellation was stored as "Something went wrong" for the next visit
        // (audit LTM-204, same fix as the Overview and the guide in e9fe0a11).
        await Task { await performLoad() }.value
        isLoading = false
    }

    private func performLoad() async {
        async let recs = liveTvService.getRecordings(userID: userID, isInProgress: nil)
        // Active recordings via the IsInProgress filter, as jellyfin-web builds its "Active Recordings" row.
        async let active = liveTvService.getRecordings(userID: userID, isInProgress: true)
        async let tims = liveTvService.getTimers()
        async let series = liveTvService.getSeriesTimers()
        do { recordings = try await recs } catch { errorMessage = ErrorText.user(for: error) }
        inProgressIDs = Set(((try? await active) ?? []).map(\.id))
        // Server returns cancelled series-spawned entries; drop them so only actionable timers appear
        // (mirrors EPGGuideViewModel.reconcileTimers).
        timers = ((try? await tims) ?? []).filter { $0.status != .cancelled }
        seriesTimers = (try? await series) ?? []
        timers.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    func deleteRecording(_ item: JellyfinItem) async {
        do {
            try await itemService.deleteItem(itemID: item.id)
            recordings.removeAll { $0.id == item.id }
        } catch { errorMessage = ErrorText.user(for: error) }
    }

    func cancelTimer(_ timer: LiveTvTimer) async {
        do {
            try await liveTvService.cancelTimer(timerID: timer.id)
            timers.removeAll { $0.id == timer.id }
        } catch { errorMessage = ErrorText.user(for: error) }
    }

    func cancelSeriesTimer(_ timer: LiveTvSeriesTimer) async {
        do {
            try await liveTvService.cancelSeriesTimer(timerID: timer.id)
            seriesTimers.removeAll { $0.id == timer.id }
            // Spawned episode timers die with the rule.
            timers.removeAll { $0.seriesTimerId == timer.id }
        } catch { errorMessage = ErrorText.user(for: error) }
    }
}
