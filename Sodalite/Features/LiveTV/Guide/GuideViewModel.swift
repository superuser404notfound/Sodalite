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
    /// The channel and program loader this guide shares with the channel list (LTM-R203).
    private let lineup: LiveLineup
    /// What the grid renders: the fetched set narrowed by the search text.
    var channels: [JellyfinChannel] { lineup.channels }
    var programsByChannel: [String: [JellyfinProgram]] { lineup.programsByChannel }
    var isLoadingChannels: Bool { lineup.isLoadingChannels }
    var channelsComplete: Bool { lineup.channelsComplete }
    var loadError: String? { lineup.loadError }
    /// Drives whether the Radio chip is offered at all. Latched: a favourites-only list without a
    /// radio channel must not take the chip away again.
    var hasRadioChannels: Bool { lineup.hasRadioChannels }

    /// Hero content: the last program focused IN THE GRID, held while focus sits on the ruler or
    /// the controls so the strip does not blank out mid-navigation.
    private(set) var heroProgram: JellyfinProgram?
    private(set) var heroChannel: JellyfinChannel?

    /// The user's time position, as a time rather than an x. It survives reloads, filter switches
    /// and jumps, and it is what vertical moves aim at.
    var anchor: GuideAnchor = .live
    /// The anchor as a moment on the current axis.
    var anchorTime: Date { anchorTime(at: Date()) }
    /// Channel row focus returns to when it comes down from the ruler.
    var anchorChannelID: String?
    /// Whether focus has been in the grid yet. Until then the first channel stands in for the hero
    /// and the landing row.
    var didEnterGrid = false

    /// Bumped when something other than the grid moved the time position (a quick target, a
    /// category snap), so the controller scrolls rather than follows.
    private(set) var scrollRequestVersion = 0

    var filter: GuideFilter { lineup.filter }
    var searchText: String { lineup.searchText }

    /// Genre narrowing (#182), applied client-side on top of `filter` and the search.
    var genres: GuideGenreController { lineup.genres }
    /// Category narrowing (#201), applied client-side like the genres.
    var categories: GuideCategoryController { lineup.categories }

    private let service: JellyfinLiveTvServiceProtocol
    private var didLoad = false
    /// The server's EPG horizon, kept because every later axis rebuild has to honour it too.
    private var guideEnd: Date?

    init(service: JellyfinLiveTvServiceProtocol,
         userID: String,
         timers: LiveTimerStore,
         metrics: GuideMetrics = .current,
         now: Date = Date()) {
        self.service = service
        self.timers = timers
        self.metrics = metrics
        let axis = GuideAxis(now: now, pointsPerMinute: metrics.pointsPerMinute)
        self.axis = axis
        self.lineup = LiveLineup(service: service, userID: userID, timers: timers,
                                 windowStart: axis.start, windowEnd: axis.end)
        lineup.genres.onSnapToNow = { [unowned self] in jumpToNow() }
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
        await lineup.fetchChannels()
    }

    /// The way back from a failed load (the error view's Retry and the app-wide reload signal). A first
    /// page that failed leaves nothing worth keeping, so the whole load runs again, probes included; a
    /// later page resumes the line-up where it stopped. A guide that loaded fine is left alone.
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
        // Programs that ended before the new left edge leave (a zero-width cell is invisible while
        // staying focusable), the rows are re-requested as they come into view, and the genre and
        // category matches are revalidated in place (LTM-203).
        lineup.setWindow(start: rebuilt.start, end: rebuilt.end)
        return true
    }

    func apply(filter newFilter: GuideFilter) async {
        guard newFilter != filter else { return }
        let categoryChanged = newFilter.category != nil && newFilter.category != filter.category
        // A category matches what is airing RIGHT NOW. Leaving the axis parked at 23:00 would show
        // channels selected for their 20:15 program, which reads as a broken filter.
        if categoryChanged { jumpToNow() }
        await lineup.apply(filter: newFilter)
    }

    func apply(searchText newValue: String) {
        lineup.apply(searchText: newValue)
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
        await lineup.ensurePrograms(for: channelIDs)
    }

    func programs(for channelID: String) -> [JellyfinProgram] {
        programsByChannel[channelID] ?? []
    }

    // MARK: - Anchor

    func anchorTime(at now: Date) -> Date {
        min(max(anchor.resolved(now: now), axis.start), axis.end)
    }

    // MARK: - Hero and navigation

    func setHero(program: JellyfinProgram?, channel: JellyfinChannel?) {
        heroProgram = program
        heroChannel = channel
    }

    /// Move the time position and tell the controller to scroll there.
    func requestScroll(to anchor: GuideAnchor) {
        self.anchor = anchor
        scrollRequestVersion += 1
    }

    func jumpToNow() { requestScroll(to: .live) }

    /// Jump to 20:15 `days` from now. Returns false when that target is past or outside the axis,
    /// so the caller can hide the chip instead of offering a jump that does nothing.
    @discardableResult
    func jumpToPrimeTime(days: Int) -> Bool {
        guard let target = axis.primeTime(days: days, from: Date()) else { return false }
        requestScroll(to: .at(target))
        return true
    }
}

/// Where vertical moves aim (Sodalite#221). Live follows the clock, so channel surfing keeps
/// landing on what airs now however long the guide stays open; a picked time stays put until a
/// horizontal move replaces it.
enum GuideAnchor: Equatable {
    case live
    case at(Date)

    /// A picked time the clock has overtaken is live again: an anchor behind the clock only ever
    /// aims at programs that have ended.
    func resolved(now: Date) -> Date {
        switch self {
        case .live: now
        case .at(let date): max(date, now)
        }
    }

    /// The anchor a horizontal move onto a cell spanning `start..<end` sets. Its start, not its
    /// midpoint, so a long block passed on the way does not drag the time hours ahead; clamped to
    /// the viewport so a block reaching in from the left aims where the user is looking.
    ///
    /// Rounded to the minute: both dates are read back from x positions, which lands a fraction of a
    /// second either side of the minute the ruler shows (Sodalite#221).
    static func focused(start: Date, visibleStart: Date, now: Date) -> GuideAnchor {
        start <= now ? .live : .at(GuideRowMath.roundToMinute(max(start, visibleStart)))
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
