import Foundation
import Observation

/// The line-up both Live TV screens read (audit LTM-R203): the channel pages for the active filter,
/// the search and genre/category narrowing, and the program rows fetched for a moving time window.
/// `GuideViewModel` (tvOS and iPad grid) and `ChannelListViewModel` (iPhone, compact iPad, Mac) keep
/// only what is theirs, the axis and anchor or the schedule days.
@Observable
@MainActor
final class LiveLineup {

    /// What the screens render: the fetched set narrowed by kind, category, genre and search.
    private(set) var channels: [JellyfinChannel] = []
    private(set) var programsByChannel: [String: [JellyfinProgram]] = [:]
    var isLoadingChannels: Bool { fetchingGeneration != nil }
    private(set) var channelsComplete = false
    private(set) var loadError: String?
    /// Latched: a favourites-only list without a radio channel must not take the chip away again.
    private(set) var hasRadioChannels = false
    private(set) var filter: GuideFilter = .default
    private(set) var searchText = ""
    /// Bumped whenever the program rows are re-opened for fetching, so a list row that is already
    /// on screen can ask again (LTM-206).
    private(set) var requestEpoch = 0

    let timers: LiveTimerStore
    let genres: GuideGenreController
    let categories: GuideCategoryController

    /// The window the program rows are fetched for.
    private(set) var windowStart: Date
    private(set) var windowEnd: Date

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    private var fetchedChannels: [JellyfinChannel] = []
    private var requestedProgramChannelIDs: Set<String> = []
    private var loadGeneration = 0
    /// The generation whose fetch loop is running. Re-entry is refused per generation only: a filter
    /// switch mid-paging has to start its own loop while the old one is still suspended in its request,
    /// which then finds itself outdated and quits.
    private var fetchingGeneration: Int?

    init(service: JellyfinLiveTvServiceProtocol, userID: String, timers: LiveTimerStore,
         windowStart: Date, windowEnd: Date) {
        self.service = service
        self.userID = userID
        self.timers = timers
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.genres = GuideGenreController(service: service, userID: userID)
        self.categories = GuideCategoryController(service: service, userID: userID)
        genres.guideWindow = { [unowned self] in (self.windowStart, self.windowEnd) }
        genres.onChannelsChanged = { [unowned self] in recomputeVisibleChannels() }
        categories.onChannelsChanged = { [unowned self] in recomputeVisibleChannels() }
    }

    var hasFetchedChannels: Bool { !fetchedChannels.isEmpty }

    // MARK: - Window

    /// Move the window. Programs that ended before the new start leave, the rows are re-opened so they
    /// are requested again (that is also what brings a long-running screen a fresh EPG), and the
    /// genre and category matches, which describe the old moment, are revalidated.
    func setWindow(start: Date, end: Date) {
        windowStart = start
        windowEnd = end
        programsByChannel = programsByChannel.mapValues { programs in
            programs.filter { ($0.endDate ?? .distantFuture) > start }
        }
        reopenProgramRows()
        genres.invalidate()
        categories.invalidate()
    }

    /// The window end only (the server's EPG horizon arrived).
    func reopenProgramRows() {
        requestedProgramChannelIDs = []
        requestEpoch += 1
    }

    // MARK: - Channels

    func clearLoadError() { loadError = nil }

    /// Pull to refresh: the set is re-asked, `channels` stays standing until the first page lands so
    /// the list does not blink empty. A "now" genre or category match is as old as its moment.
    func refresh() async {
        loadGeneration += 1
        fetchedChannels = []
        channelsComplete = false
        reopenProgramRows()
        genres.invalidate()
        categories.invalidate()
        await fetchChannels()
    }

    func reload() async {
        loadGeneration += 1
        fetchedChannels = []
        channels = []
        programsByChannel = [:]
        requestedProgramChannelIDs = []
        channelsComplete = false
        await fetchChannels()
    }

    func apply(filter newFilter: GuideFilter) async {
        guard newFilter != filter else { return }
        let refetch = newFilter.queryItems != filter.queryItems
        filter = newFilter
        if refetch {
            async let resolved: Void = categories.apply(newFilter.category)
            await reload()
            await resolved
        } else {
            // Kind and category narrow what is already fetched. The category's resolve empties the
            // set in the same turn, so the screen never shows the unnarrowed list in between.
            recomputeVisibleChannels()
            await categories.apply(newFilter.category)
        }
    }

    func apply(searchText newValue: String) {
        searchText = newValue
        recomputeVisibleChannels()
    }

    /// Fetch every page for the active filter, appending progressively so the first page renders
    /// while the rest arrives.
    func fetchChannels() async {
        let generation = loadGeneration
        guard fetchingGeneration != generation else { return }
        fetchingGeneration = generation
        defer { if fetchingGeneration == generation { fetchingGeneration = nil } }
        var startIndex = fetchedChannels.count
        while !channelsComplete, startIndex < GuideViewModel.channelHardCap {
            do {
                let response = try await service.getChannels(
                    userID: userID, startIndex: startIndex, limit: GuideViewModel.pageSize, filter: filter)
                // A filter switch during the loop invalidates everything fetched after it.
                guard generation == loadGeneration else { return }
                fetchedChannels.append(contentsOf: response.items)
                timers.seedFavorites(from: response.items)
                // Read off the channels themselves: Jellyfin drops a Type=Radio filter, so a probe
                // for one answered yes on every server with Live TV (#201).
                if response.items.contains(where: { $0.kind == .radio }) { hasRadioChannels = true }
                startIndex += response.items.count
                // A page that came back empty also ends the loop, or a server that ignores
                // StartIndex would spin here forever.
                if response.items.count < GuideViewModel.pageSize { channelsComplete = true }
                loadError = nil
                recomputeVisibleChannels()
            } catch {
                guard generation == loadGeneration else { return }
                loadError = ErrorText.user(for: error)
                return
            }
        }
        channelsComplete = true
    }

    private func recomputeVisibleChannels() {
        let query = searchText
        channels = fetchedChannels.filter { channel in
            filter.admits(kindOf: channel) && categories.admits(channel) && genres.admits(channel)
                && (query.isEmpty || GuideViewModel.matches(channel: channel, query: query))
        }
    }

    // MARK: - Programs

    /// Fetch programs for not-yet-requested channels as their rows come into view.
    func ensurePrograms(for channelIDs: [String]) async {
        let missing = channelIDs.filter { !requestedProgramChannelIDs.contains($0) }
        guard !missing.isEmpty else { return }
        missing.forEach { requestedProgramChannelIDs.insert($0) }
        do {
            let programs = try await service.getPrograms(
                channelIDs: missing, userID: userID, start: windowStart, end: windowEnd)
            var grouped = programsByChannel
            // A row can be requested a second time after the window moved. Replace it: appending
            // would leave the old and the new copy of a program side by side, and two entries that
            // overlap without covering each other both survive GuideRowMath.
            missing.forEach { grouped[$0] = [] }
            for program in programs {
                guard let channelID = program.channelId else { continue }
                // The MinEndDate overlap query is inclusive, so a program ending exactly at the window
                // start has zero span and would render as a one-point sliver. Read live, after the
                // await, which is also what keeps a response that was requested for the PREVIOUS
                // window from putting its expired programs back into a row.
                if let end = program.endDate, end <= windowStart { continue }
                grouped[channelID, default: []].append(program)
            }
            for channelID in missing {
                guard var row = grouped[channelID] else { continue }
                row.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                // Overlapping EPG entries stack two cells on the same pixels, and the one behind
                // stays focusable while being invisible. Sanitized here so the anchor's program
                // index and the rendered cells count the same programs.
                let kept = GuideRowMath.keptIndices(row.map(\.guideTimeRange))
                grouped[channelID] = kept.map { row[$0] }
            }
            programsByChannel = grouped
            timers.seedTimers(from: programs)
        } catch {
            // Leave the rows program-less and allow a retry.
            missing.forEach { requestedProgramChannelIDs.remove($0) }
        }
    }
}
