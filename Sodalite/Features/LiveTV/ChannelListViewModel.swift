import Foundation
import Observation

/// The iPhone's Live TV state. A grid at phone scale is not usable, so compact gets a channel list
/// that leads with what is on now and what follows, and defers the full schedule to a sheet.
@Observable
@MainActor
final class ChannelListViewModel {

    /// The channel and program loader this list shares with the guide (LTM-R203).
    private let lineup: LiveLineup
    var channels: [JellyfinChannel] { lineup.channels }
    var programsByChannel: [String: [JellyfinProgram]] { lineup.programsByChannel }
    var isLoading: Bool { lineup.isLoadingChannels }
    var loadError: String? { lineup.loadError }
    /// Latched, see GuideViewModel.hasRadioChannels.
    var hasRadioChannels: Bool { lineup.hasRadioChannels }
    var filter: GuideFilter { lineup.filter }
    var searchText: String { lineup.searchText }
    /// See LiveLineup.requestEpoch: a visible row re-asks for its schedule when this changes.
    var requestEpoch: Int { lineup.requestEpoch }

    var timers: LiveTimerStore { lineup.timers }
    /// Genre narrowing (#182), shared with the guide grid.
    var genres: GuideGenreController { lineup.genres }
    /// Category narrowing (#201), shared with the guide grid.
    var categories: GuideCategoryController { lineup.categories }

    private var didLoad = false

    init(service: JellyfinLiveTvServiceProtocol, userID: String, timers: LiveTimerStore, now: Date = Date()) {
        let window = Self.window(at: now)
        self.lineup = LiveLineup(service: service, userID: userID, timers: timers,
                                 windowStart: window.start, windowEnd: window.end)
    }

    /// Two days from the current half hour, the same horizon and rounding the grid uses.
    static func window(at now: Date) -> (start: Date, end: Date) {
        let start = GuideAxis.floorToSlot(now)
        return (start, start.addingTimeInterval(GuideAxis.defaultSpan))
    }

    /// The two days the schedule sheet offers, matching the grid's axis.
    var scheduleDays: [Date] {
        [lineup.windowStart, Calendar.current.date(byAdding: .day, value: 1, to: lineup.windowStart) ?? lineup.windowStart]
    }

    // MARK: - Loading

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        await lineup.fetchChannels()
    }

    /// LTM-206: the list outlives its window (a Mac app left running overnight), so the window is
    /// re-derived from the clock and the rows re-requested. Returns true when it moved.
    @discardableResult
    func refreshWindow(now: Date = Date()) -> Bool {
        let window = Self.window(at: now)
        guard window.start != lineup.windowStart else { return false }
        lineup.setWindow(start: window.start, end: window.end)
        return true
    }

    /// Pull to refresh. The window is re-derived and every row's schedule re-requested along with
    /// the channel list. `channels` is left standing until the first page lands, so the list does
    /// not blink empty under the user's finger.
    func refresh() async {
        refreshWindow()
        await lineup.refresh()
    }

    /// See GuideViewModel.recover().
    func recover() async {
        guard lineup.loadError != nil else { return }
        lineup.clearLoadError()
        if lineup.hasFetchedChannels {
            await lineup.fetchChannels()
        } else {
            didLoad = false
            await load()
        }
    }

    /// See GuideViewModel.apply(filter:).
    func apply(filter newFilter: GuideFilter) async {
        await lineup.apply(filter: newFilter)
    }

    func apply(searchText newValue: String) {
        lineup.apply(searchText: newValue)
    }

    // MARK: - Programs

    func ensurePrograms(for channelIDs: [String]) async {
        await lineup.ensurePrograms(for: channelIDs)
    }

    func schedule(for channel: JellyfinChannel) -> [JellyfinProgram] {
        programsByChannel[channel.id] ?? []
    }

    /// `AddCurrentProgram=true` already delivers this with the channel list, so the row's first line
    /// needs no extra request; the fetched schedule only refines it once loaded.
    func currentProgram(for channel: JellyfinChannel) -> JellyfinProgram? {
        Self.currentProgram(at: Date(), in: schedule(for: channel), fallback: channel.currentProgram)
    }

    /// What is airing at `reference`. The fallback is the snapshot the channel list arrived with, so
    /// it only answers for a channel whose schedule has not loaded yet; once it has, the row follows
    /// the schedule and the clock rather than that one moment (#96).
    static func currentProgram(at reference: Date, in schedule: [JellyfinProgram],
                               fallback: JellyfinProgram?) -> JellyfinProgram? {
        if let fromSchedule = schedule.first(where: { $0.isAiring(at: reference) }) {
            return fromSchedule
        }
        guard let fallback else { return nil }
        // A schedule that is loaded and says nothing is airing has answered; the snapshot would only
        // repeat a program that ended.
        return schedule.isEmpty ? fallback : nil
    }

    func nextProgram(for channel: JellyfinChannel) -> JellyfinProgram? {
        Self.nextProgram(after: Date(), in: schedule(for: channel))
    }

    /// First program starting at or after `reference`. A gap in the schedule is not an end: the
    /// entry after the gap is still what comes next.
    static func nextProgram(after reference: Date, in schedule: [JellyfinProgram]) -> JellyfinProgram? {
        schedule.first { program in
            guard let start = program.startDate else { return false }
            return start >= reference
        }
    }

    /// The channel's programs on one calendar day, for the schedule sheet.
    func schedule(for channel: JellyfinChannel, on day: Date) -> [JellyfinProgram] {
        let calendar = Calendar.current
        return (programsByChannel[channel.id] ?? []).filter { program in
            guard let start = program.startDate else { return false }
            return calendar.isDate(start, inSameDayAs: day)
        }
    }
}
