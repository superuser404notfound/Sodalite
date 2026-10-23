import Foundation
import Observation

/// Everything the rebuilt guide reads: the channel list for the active filter, the programs loaded
/// for visible rows, the time axis, and the anchor that keeps the user's time position across
/// vertical moves and jumps.
@Observable
@MainActor
final class GuideViewModel {

    /// Channels are fetched in full rather than 50-at-a-time, because client-side search needs the
    /// whole set and the scroll-triggered page load was a visible stutter. 200 is a compromise
    /// between round trips and first-page latency.
    static let pageSize = 200
    /// IPTV playlists can carry tens of thousands of entries. Past this the guide stops fetching;
    /// the search cover says so rather than pretending the set is complete.
    static let channelHardCap = 2000

    let metrics: GuideMetrics
    let timers: LiveTimerStore

    private(set) var axis: GuideAxis
    /// What the grid renders: the fetched set narrowed by the search text.
    private(set) var channels: [JellyfinChannel] = []
    private(set) var programsByChannel: [String: [JellyfinProgram]] = [:]
    var isLoadingChannels: Bool { fetchingGeneration != nil }
    private(set) var channelsComplete = false
    private(set) var loadError: String?
    /// Drives whether the Radio chip is offered at all. Latched: a favourites-only list without a
    /// radio channel must not take the chip away again.
    private(set) var hasRadioChannels = false

    /// Hero content: the last program focused IN THE GRID, held while focus sits on the ruler or
    /// the controls so the strip does not blank out mid-navigation.
    private(set) var heroProgram: JellyfinProgram?
    private(set) var heroChannel: JellyfinChannel?

    /// The user's time position, as a time rather than an x. It survives reloads, filter switches
    /// and jumps, and it is what the ruler hands back when focus returns to the grid.
    var anchorTime: Date
    /// Channel row focus returns to when it comes down from the ruler.
    var anchorChannelID: String?

    /// Bumped when something other than the grid moved the time position (a quick target, a
    /// category snap), so the controller scrolls rather than follows.
    private(set) var scrollRequestVersion = 0

    private(set) var filter: GuideFilter = .default
    private(set) var searchText = ""

    /// Genre narrowing (#182), applied client-side on top of `filter` and the search.
    let genres: GuideGenreController
    /// Category narrowing (#201), applied client-side like the genres.
    let categories: GuideCategoryController

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    /// Everything fetched for the active filter, before the search narrows it.
    private var fetchedChannels: [JellyfinChannel] = []
    private var requestedProgramChannelIDs: Set<String> = []
    private var loadGeneration = 0
    /// The generation whose fetch loop is running. Re-entry is refused per generation only: a filter
    /// switch mid-paging has to start its own loop while the old one is still suspended in its request,
    /// which then finds itself outdated and quits.
    private var fetchingGeneration: Int?
    private var didLoad = false
    /// The server's EPG horizon, kept because every later axis rebuild has to honour it too.
    private var guideEnd: Date?

    init(service: JellyfinLiveTvServiceProtocol,
         userID: String,
         timers: LiveTimerStore,
         metrics: GuideMetrics = .current,
         now: Date = Date()) {
        self.service = service
        self.userID = userID
        self.timers = timers
        self.metrics = metrics
        self.axis = GuideAxis(now: now, pointsPerMinute: metrics.pointsPerMinute)
        self.anchorTime = now
        self.genres = GuideGenreController(service: service, userID: userID)
        self.categories = GuideCategoryController(service: service, userID: userID)
        genres.guideWindow = { [unowned self] in (axis.start, axis.end) }
        genres.onSnapToNow = { [unowned self] in jumpToNow() }
        genres.onChannelsChanged = { [unowned self] in recomputeVisibleChannels() }
        categories.onChannelsChanged = { [unowned self] in recomputeVisibleChannels() }
    }

    var allLoadedPrograms: [JellyfinProgram] { programsByChannel.values.flatMap { $0 } }

    // MARK: - Loading

    /// Guide bounds and the channel list. Safe to call repeatedly; only the first call does work.
    func load() async {
        guard !didLoad else { return }
        didLoad = true
        // Owned by the model, not by the caller: a page rebuilt under a profile switch cancels the
        // task that asked, and a cancelled first page landed as a load error that only Retry undid.
        await Task { await performLoad() }.value
    }

    private func performLoad() async {
        // The axis is rebuilt once the server's horizon is known, BEFORE any program fetch: a 12h
        // guide should not render 36h of empty canvas, and the ruler's chip count comes off the axis.
        if let end = (try? await service.getGuideInfo())?.endDate {
            guideEnd = end
            refreshAxis()
        }
        await fetchChannels()
    }

    /// The way back from a failed load (the error view's Retry and the app-wide reload signal). A first
    /// page that failed leaves nothing worth keeping, so the whole load runs again, probes included; a
    /// later page resumes the line-up where it stopped. A guide that loaded fine is left alone.
    func recover() async {
        guard loadError != nil else { return }
        loadError = nil
        if fetchedChannels.isEmpty {
            didLoad = false
            await load()
        } else {
            await fetchChannels()
        }
    }

    // MARK: - Time

    /// Re-derive the window from the current moment.
    ///
    /// Sodalite#138: the axis is a snapshot of "now" and the guide outlives it. The cells are placed
    /// by absolute time and the now line ticks, so an hours-old axis is wrong and right about the
    /// clock in the same frame: the left edge stays on the half hour in which Live TV was opened
    /// while the airing outlines sit correctly further right. Returns true when the window moved, so
    /// the caller knows the geometry cached from it is stale.
    @discardableResult
    func refreshAxis(now: Date = Date()) -> Bool {
        let rebuilt = GuideAxis(now: now, pointsPerMinute: metrics.pointsPerMinute, guideEnd: guideEnd)
        guard rebuilt != axis else { return false }
        axis = rebuilt
        // A program that ended before the new left edge has no width left (GuideAxis.width answers
        // 0 and GuideRowMath.spans clamps x to 0), and a zero-width cell is invisible while staying
        // focusable. It leaves with the window rather than piling up at x = 0.
        programsByChannel = programsByChannel.mapValues { programs in
            programs.filter { ($0.endDate ?? .distantFuture) > rebuilt.start }
        }
        // The rows were fetched for the OLD window, which no longer covers this one: re-open them so
        // they are requested again as they come into view. That is also the only thing that brings a
        // long-running guide a fresh EPG.
        requestedProgramChannelIDs = []
        anchorTime = min(max(anchorTime, rebuilt.start), rebuilt.end)
        genres.invalidate()
        categories.invalidate()
        return true
    }

    func apply(filter newFilter: GuideFilter) async {
        guard newFilter != filter else { return }
        let categoryChanged = newFilter.category != nil && newFilter.category != filter.category
        let refetch = newFilter.queryItems != filter.queryItems
        filter = newFilter
        // A category matches what is airing RIGHT NOW. Leaving the axis parked at 23:00 would show
        // channels selected for their 20:15 program, which reads as a broken filter.
        if categoryChanged { jumpToNow() }
        if refetch {
            async let resolved: Void = categories.apply(newFilter.category)
            await reloadChannels()
            await resolved
        } else {
            // Kind and category narrow what is already fetched. The category's resolve empties the
            // set in the same turn, so the grid never shows the unnarrowed list in between.
            recomputeVisibleChannels()
            await categories.apply(newFilter.category)
        }
    }

    func apply(searchText newValue: String) {
        searchText = newValue
        recomputeVisibleChannels()
    }

    private func reloadChannels() async {
        loadGeneration += 1
        fetchedChannels = []
        channels = []
        programsByChannel = [:]
        requestedProgramChannelIDs = []
        channelsComplete = false
        await fetchChannels()
    }

    /// Fetch every page for the active filter, appending progressively so the first page renders
    /// while the rest arrives.
    private func fetchChannels() async {
        let generation = loadGeneration
        guard fetchingGeneration != generation else { return }
        fetchingGeneration = generation
        defer { if fetchingGeneration == generation { fetchingGeneration = nil } }
        var startIndex = fetchedChannels.count
        while !channelsComplete, startIndex < Self.channelHardCap {
            do {
                let response = try await service.getChannels(
                    userID: userID, startIndex: startIndex, limit: Self.pageSize, filter: filter)
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
                if response.items.count < Self.pageSize { channelsComplete = true }
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
                && (query.isEmpty || Self.matches(channel: channel, query: query))
        }
    }

    // MARK: - Search matching

    /// Name substring or channel-number prefix, case- and diacritic-insensitive. Number matching is
    /// a prefix on purpose: containment would make "3" drag in channel 13 and 30.
    static func matches(channel: JellyfinChannel, query: String) -> Bool {
        let needle = query.guideFolded
        guard !needle.isEmpty else { return true }
        if channel.name.guideFolded.contains(needle) { return true }
        if let number = channel.channelNumber?.guideFolded, number.hasPrefix(needle) { return true }
        return false
    }

    // MARK: - Programs

    /// Fetch programs for not-yet-requested channels as their rows come into view.
    func ensurePrograms(for channelIDs: [String]) async {
        let missing = channelIDs.filter { !requestedProgramChannelIDs.contains($0) }
        guard !missing.isEmpty else { return }
        missing.forEach { requestedProgramChannelIDs.insert($0) }
        do {
            let programs = try await service.getPrograms(
                channelIDs: missing, userID: userID, start: axis.start, end: axis.end)
            var grouped = programsByChannel
            // A row can be requested a second time after the window moved. Replace it: appending
            // would leave the old and the new copy of a program side by side, and two entries that
            // overlap without covering each other both survive GuideRowMath.
            missing.forEach { grouped[$0] = [] }
            for program in programs {
                guard let channelID = program.channelId else { continue }
                // The MinEndDate overlap query is inclusive, so a program ending exactly at the axis
                // start has zero span and would render as a one-point sliver. Read live, after the
                // await, which is also what keeps a response that was requested for the PREVIOUS
                // window from putting its expired programs back into a row.
                if let end = program.endDate, end <= axis.start { continue }
                grouped[channelID, default: []].append(program)
            }
            for channelID in missing {
                guard var row = grouped[channelID] else { continue }
                row.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                // Overlapping EPG entries stack two cells on the same pixels, and the one behind
                // stays focusable while being invisible. Sanitized here, not in the grid, so the
                // anchor's program index and the rendered cells count the same programs.
                let kept = GuideRowMath.keptIndices(row.map(\.guideTimeRange))
                grouped[channelID] = kept.map { row[$0] }
            }
            programsByChannel = grouped
            timers.seedTimers(from: programs)
        } catch {
            // Leave the rows program-less (the grid shows a placeholder) and allow a retry.
            missing.forEach { requestedProgramChannelIDs.remove($0) }
        }
    }

    func programs(for channelID: String) -> [JellyfinProgram] {
        programsByChannel[channelID] ?? []
    }

    /// Index of the program covering `time` on that channel, or the nearest one when the row has a
    /// gap there. nil when the row has no programs at all.
    func programIndex(coveringOrNearest time: Date, in channelID: String) -> Int? {
        let programs = programs(for: channelID)
        guard !programs.isEmpty else { return nil }
        var best = 0
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        for (index, program) in programs.enumerated() {
            guard let start = program.startDate, let end = program.endDate else { continue }
            if time >= start && time < end { return index }
            let distance = time < start ? start.timeIntervalSince(time) : time.timeIntervalSince(end)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Hero and navigation

    func setHero(program: JellyfinProgram?, channel: JellyfinChannel?) {
        heroProgram = program
        heroChannel = channel
    }

    /// Move the time position and tell the controller to scroll there.
    func requestScroll(to date: Date) {
        anchorTime = min(max(date, axis.start), axis.end)
        scrollRequestVersion += 1
    }

    func jumpToNow() { requestScroll(to: Date()) }

    /// Jump to 20:15 `days` from now. Returns false when that target is past or outside the axis,
    /// so the caller can hide the chip instead of offering a jump that does nothing.
    @discardableResult
    func jumpToPrimeTime(days: Int) -> Bool {
        guard let target = axis.primeTime(days: days, from: Date()) else { return false }
        requestScroll(to: target)
        return true
    }
}

extension String {
    /// Case- and diacritic-insensitive form used by the channel search on both sides of the compare.
    /// whitespacesAndNewlines, not whitespaces: the latter leaves a newline standing, and a query
    /// that folds to a bare "\n" matches no channel name and empties the grid.
    var guideFolded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
