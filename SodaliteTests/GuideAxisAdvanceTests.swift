import Testing
import Foundation
import CoreGraphics
@testable import Sodalite

/// Sodalite#138: the axis is a snapshot of "now" taken once at construction, and the guide outlives
/// it. The cells knew what time it was (they are placed by absolute time and the airing outline
/// ticks) while the left edge stayed on the half hour in which Live TV was first opened.
@MainActor
struct GuideAxisAdvanceTests {

    /// A real slot boundary in whatever calendar this machine runs in, so a half-hour-offset zone
    /// cannot move the boundaries the expectations are written against.
    private let slotStart = GuideAxis.floorToSlot(Date(timeIntervalSince1970: 1_800_000_000))
    private let slot = TimeInterval(GuideAxis.slotMinutes * 60)

    private func program(_ id: String, start: Date, end: Date) -> JellyfinProgram {
        JellyfinProgram(
            id: id, channelId: "c1", channelName: "Test", name: id, overview: nil,
            startDate: start, endDate: end,
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    private func model(now: Date, service: StubGuideService = StubGuideService()) -> GuideViewModel {
        GuideViewModel(service: service, userID: "u",
                       timers: LiveTimerStore(service: service, userID: "u"),
                       metrics: .tv, now: now)
    }

    // MARK: - The window itself

    @Test("a refresh inside the same half hour is not a new window")
    func withinTheSlotNothingMoves() {
        let model = model(now: slotStart + 60)
        #expect(model.refreshAxis(now: slotStart + 29 * 60) == false)
        #expect(model.axis.start == slotStart)
    }

    @Test("crossing the half hour moves the left edge to it")
    func crossingTheSlotAdvances() {
        let model = model(now: slotStart + 60)
        #expect(model.refreshAxis(now: slotStart + slot + 4 * 60) == true)
        #expect(model.axis.start == slotStart + slot)
    }

    @Test("two hours later the window begins two hours later, not where the app was opened")
    func hoursOfDriftAreRecovered() {
        let model = model(now: slotStart + 11 * 60)
        model.refreshAxis(now: slotStart + 2 * 3600 + 4 * 60)
        #expect(model.axis.start == slotStart + 2 * 3600)
    }

    @Test("the server's guide horizon survives the rebuild")
    func guideHorizonIsKept() async {
        let horizon = GuideAxis.floorToSlot(Date()).addingTimeInterval(12 * 3600)
        let model = model(now: Date(), service: StubGuideService(guideEnd: horizon))
        await model.load()
        #expect(model.axis.end == horizon)

        let later = model.axis.start.addingTimeInterval(slot + 60)
        #expect(model.refreshAxis(now: later) == true)
        #expect(model.axis.start == GuideAxis.floorToSlot(later))
        // Without the horizon the rebuild would hand back a full 48h span of empty canvas.
        #expect(model.axis.end == horizon)
    }

    @Test("the time position moves up with the window instead of pointing outside it")
    func anchorIsClamped() {
        let model = model(now: slotStart + 60)
        #expect(model.anchorTime == slotStart + 60)
        model.refreshAxis(now: slotStart + 2 * slot)
        #expect(model.anchorTime == model.axis.start)
    }

    // MARK: - What the moved window does to the programmes already fetched

    @Test("programmes that ended before the new left edge leave with it")
    func staleProgramsArePruned() async {
        let service = StubGuideService(programs: [
            program("ended", start: slotStart - 600, end: slotStart + 20 * 60),
            program("running", start: slotStart + 20 * 60, end: slotStart + 80 * 60),
        ])
        let model = model(now: slotStart + 5 * 60, service: service)
        await model.ensurePrograms(for: ["c1"])
        #expect(model.programs(for: "c1").count == 2)

        model.refreshAxis(now: slotStart + slot + 60)
        // Left where it was, "ended" would keep a zero-width but focusable cell at x = 0:
        // GuideRowMath.spans clamps x to 0 and GuideAxis.width answers 0 for it.
        #expect(model.programs(for: "c1").map(\.id) == ["running"])
    }

    @Test("a moved window re-requests the rows whose fetch no longer covers it")
    func advanceReopensTheFetch() async {
        let service = StubGuideService(programs: [
            program("running", start: slotStart + 20 * 60, end: slotStart + 80 * 60),
        ])
        let model = model(now: slotStart + 5 * 60, service: service)
        await model.ensurePrograms(for: ["c1"])
        #expect(service.programRequests == 1)

        model.refreshAxis(now: slotStart + slot + 60)
        await model.ensurePrograms(for: ["c1"])
        #expect(service.programRequests == 2)
    }

    @Test("a re-requested row is replaced, not stacked on top of itself")
    func refetchReplacesTheRow() async {
        let service = StubGuideService(programs: [
            program("running", start: slotStart + 20 * 60, end: slotStart + 80 * 60),
        ])
        // The second answer is what a live EPG does: the same programme, ten minutes longer. Two
        // entries that overlap without covering each other survive GuideRowMath, so an appending
        // merge would leave the row holding both.
        service.secondAnswer = [
            program("running", start: slotStart + 20 * 60, end: slotStart + 90 * 60),
        ]
        let model = model(now: slotStart + 5 * 60, service: service)
        await model.ensurePrograms(for: ["c1"])
        model.refreshAxis(now: slotStart + slot + 60)
        await model.ensurePrograms(for: ["c1"])

        #expect(model.programs(for: "c1").count == 1)
        #expect(model.programs(for: "c1").first?.endDate == slotStart + 90 * 60)
    }

    // MARK: - What the grid does with it

    @Test("the viewport keeps its wall clock when the window moves under it")
    func offsetPreservesTheLeadingTime() {
        let before = GuideAxis(now: slotStart, pointsPerMinute: 8)
        let after = GuideAxis(now: slotStart + slot, pointsPerMinute: 8)
        let looking = slotStart + 4 * 3600
        let kept = GuideGridViewController.preservedOffset(
            date: before.date(atX: before.x(for: looking)), axis: after, viewportWidth: 1000)
        #expect(after.date(atX: kept) == looking)
    }

    @Test("a viewport that was left of the new window lands on its edge, not on a negative offset")
    func offsetClampsAtBothEnds() {
        let after = GuideAxis(now: slotStart + slot, pointsPerMinute: 8)
        #expect(GuideGridViewController.preservedOffset(
            date: slotStart, axis: after, viewportWidth: 1000) == 0)
        #expect(GuideGridViewController.preservedOffset(
            date: after.end, axis: after, viewportWidth: 1000) == after.totalWidth - 1000)
    }
}

/// Answers the guide's three startup questions and counts the programme requests, which is how the
/// refetch policy is observed.
private final class StubGuideService: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    let guideEnd: Date?
    let programs: [JellyfinProgram]
    /// Handed out instead of `programs` from the second request on.
    var secondAnswer: [JellyfinProgram]?

    private let lock = NSLock()
    private var requests = 0
    var programRequests: Int { lock.withLock { requests } }

    init(guideEnd: Date? = nil, programs: [JellyfinProgram] = []) {
        self.guideEnd = guideEnd
        self.programs = programs
    }

    func getPrograms(channelIDs: [String], userID: String,
                     start: Date, end: Date) async throws -> [JellyfinProgram] {
        let count = lock.withLock { () -> Int in
            requests += 1
            return requests
        }
        let answer = count > 1 ? (secondAnswer ?? programs) : programs
        return answer.filter { ($0.endDate ?? .distantFuture) > start && ($0.startDate ?? .distantPast) < end }
    }

    func getGuideInfo() async throws -> JellyfinGuideInfo {
        JellyfinGuideInfo(startDate: nil, endDate: guideEnd)
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(items: [], totalRecordCount: 0)
    }
    func getRecommendedPrograms(userID: String, category: LiveProgramCategory,
                                limit: Int) async throws -> [JellyfinProgram] { [] }
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
    func getTimers() async throws -> [LiveTvTimer] { [] }
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
    func createTimer(programID: String) async throws {}
    func cancelTimer(timerID: String) async throws {}
    func createSeriesTimer(programID: String) async throws {}
    func cancelSeriesTimer(timerID: String) async throws {}
}
