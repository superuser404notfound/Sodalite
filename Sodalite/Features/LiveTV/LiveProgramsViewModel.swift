import SwiftUI
import Observation

/// Backs the "Übersicht" tab: fetches recommended programs per category and synthesizes the channel
/// a tapped program needs. Timer/favorite state is intentionally NOT here; the view reuses the shared
/// `EPGGuideViewModel` for those so the optimistic overlay stays consistent across all three segments.
@Observable
@MainActor
final class LiveProgramsViewModel {
    /// Programs per category. Categories with an empty array are not rendered.
    private(set) var rows: [LiveProgramCategory: [JellyfinProgram]] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// When the loaded snapshot stops describing "now", and nil until the first fetch succeeds.
    /// `/LiveTv/Programs/Recommended` answers a question about the current moment, so its answer
    /// carries an expiry: the first airing program to end is the first card that becomes a lie.
    /// The guide does not need this because its cells are placed by absolute time; these rows are a
    /// snapshot and go stale on their own (#96).
    private(set) var validUntil: Date?

    /// Per-row item cap, matches jellyfin-web's recommended view.
    private static let limit = 20
    /// Floor on a snapshot's lifetime. On a channel line-up with many short programs some entry ends
    /// every few seconds, and without this the expiry would land in the past on arrival.
    static let minimumLifetime: TimeInterval = 120
    /// Used when nothing in the answer is airing, so there is no end date to expire on.
    static let unknownScheduleLifetime: TimeInterval = 600

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    /// The fetch under way, owned by the model rather than by whichever view asked for it. A tab page
    /// rebuilt by a profile switch cancels the task that started the load, and a cancelled request
    /// came back as "every category failed": the error page stood until the next tab change.
    private var inFlight: Task<Void, Never>?

    init(service: JellyfinLiveTvServiceProtocol, userID: String) {
        self.service = service
        self.userID = userID
    }

    /// First fill. Idempotent: only the fetch that has not produced a snapshot yet does work.
    func load() async {
        guard validUntil == nil else { return }
        await fetch()
    }

    /// Refetch once the snapshot has stopped describing "now". A no-op (no request) while it still
    /// does, so appearance, a returning player and the clock can all call it freely.
    func refreshIfExpired(now: Date = Date()) async {
        guard let validUntil else { return await fetch() }
        guard now >= validUntil else { return }
        await fetch()
    }

    /// Unconditional refetch (pull to refresh on iOS).
    func refresh() async {
        await fetch()
    }

    /// How long the current snapshot is still good for, floored so an expiry that already passed
    /// cannot turn the caller's wait into a busy loop.
    func secondsUntilExpiry(from now: Date = Date()) -> TimeInterval {
        guard let validUntil else { return Self.unknownScheduleLifetime }
        return max(validUntil.timeIntervalSince(now), 30)
    }

    /// The moment the rows stop describing "now": the earliest end among the programs that were
    /// airing when they arrived.
    static func expiry(for rows: [LiveProgramCategory: [JellyfinProgram]], loadedAt: Date) -> Date {
        let earliestEnd = rows.values
            .flatMap { $0 }
            .filter { $0.isAiring(at: loadedAt) }
            .compactMap(\.endDate)
            .filter { $0 > loadedAt }
            .min()
        let target = earliestEnd ?? loadedAt.addingTimeInterval(unknownScheduleLifetime)
        return max(target, loadedAt.addingTimeInterval(minimumLifetime))
    }

    /// One fetch at a time, shared: a second caller waits for the one under way instead of returning
    /// at once and sleeping a whole lifetime on a snapshot that may never arrive.
    private func fetch() async {
        if let inFlight { return await inFlight.value }
        let task = Task { await performFetch() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Fan out one recommended-programs call per category.
    private func performFetch() async {
        isLoading = true
        defer { isLoading = false }
        let startedAt = Date()

        await withTaskGroup(of: (LiveProgramCategory, [JellyfinProgram]?).self) { group in
            for category in LiveProgramCategory.allCases {
                group.addTask { [service, userID] in
                    let programs = try? await service.getRecommendedPrograms(
                        userID: userID, category: category, limit: Self.limit)
                    return (category, programs)
                }
            }
            var collected: [LiveProgramCategory: [JellyfinProgram]] = [:]
            var anySucceeded = false
            for await (category, programs) in group {
                if let programs {
                    anySucceeded = true
                    if !programs.isEmpty { collected[category] = programs }
                }
            }
            // A partial failure still renders the loaded rows; a total failure over rows that are
            // already on screen keeps them and stays quiet, because a stale row beats an error page.
            guard anySucceeded else {
                if rows.isEmpty {
                    loadError = String(
                        localized: "livetv.loadFailed.title", defaultValue: "Couldn't load programs")
                } else {
                    // The expiry is what the clock sleeps to, so leaving it in the past would ask an
                    // unreachable server again every thirty seconds for as long as the tab is open.
                    // The rows are stale either way; the next attempt can wait a lifetime.
                    validUntil = startedAt.addingTimeInterval(Self.minimumLifetime)
                }
                return
            }
            // Only when it actually differs: on tvOS an assignment rebuilds the rows, and a card
            // that is rebuilt under the focus engine is a card the focus engine may leave. Most
            // refreshes land on an unchanged schedule and have nothing to say.
            if collected != rows { rows = collected }
            validUntil = Self.expiry(for: collected, loadedAt: startedAt)
            loadError = nil
        }
    }

    /// The `JellyfinChannel` a tapped program needs. Prefers the guide's real channel (logo tag,
    /// favorite state) if loaded; else synthesizes a minimal one from program id+name, decoupled from
    /// the guide's 50-at-a-time pagination.
    func channel(for program: JellyfinProgram, guideChannels: [JellyfinChannel]) -> JellyfinChannel? {
        guard let channelID = program.channelId else { return nil }
        if let real = guideChannels.first(where: { $0.id == channelID }) {
            return real
        }
        return JellyfinChannel(
            id: channelID,
            name: program.channelName ?? program.name,
            channelNumber: nil,
            imageTags: nil,
            currentProgram: nil,
            userData: nil
        )
    }
}
