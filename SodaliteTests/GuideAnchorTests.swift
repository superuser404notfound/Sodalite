import Testing
import Foundation
@testable import Sodalite

/// Sodalite#221: Up and Down in the guide aim at a time the user can predict. Live until a later
/// time is picked, that time until the next horizontal move, and live again once back on what airs.
@MainActor
struct GuideAnchorTests {

    private let slotStart = GuideAxis.floorToSlot(Date(timeIntervalSince1970: 1_800_000_000))
    private let minute: TimeInterval = 60

    private func model(now: Date) -> GuideViewModel {
        let service = StubGuideService()
        return GuideViewModel(service: service, userID: "u",
                              timers: LiveTimerStore(service: service, userID: "u"),
                              metrics: .tv, now: now)
    }

    @Test("a fresh guide is live and follows the clock")
    func freshGuideIsLive() {
        let model = model(now: slotStart + 5 * minute)
        #expect(model.anchor == .live)
        #expect(model.anchorTime(at: slotStart + 5 * minute) == slotStart + 5 * minute)
        #expect(model.anchorTime(at: slotStart + 25 * minute) == slotStart + 25 * minute)
    }

    @Test("a picked later time stays put while the clock moves")
    func pickedTimeStays() {
        let model = model(now: slotStart)
        model.anchor = .at(slotStart + 120 * minute)
        #expect(model.anchorTime(at: slotStart + 10 * minute) == slotStart + 120 * minute)
        #expect(model.anchorTime(at: slotStart + 60 * minute) == slotStart + 120 * minute)
    }

    @Test("a picked time the clock overtook aims at now, not at programs that ended")
    func overtakenTimeIsLive() {
        #expect(GuideAnchor.at(slotStart).resolved(now: slotStart + 20 * minute)
                == slotStart + 20 * minute)
    }

    @Test("the anchor never points outside the window")
    func anchorIsClampedToAxis() {
        let model = model(now: slotStart)
        model.anchor = .at(model.axis.end + 3600)
        #expect(model.anchorTime(at: slotStart) == model.axis.end)
        model.anchor = .live
        #expect(model.anchorTime(at: slotStart - 3600) == model.axis.start)
    }

    @Test("moving onto a program that airs goes live, wherever it started")
    func airingProgramIsLive() {
        let now = slotStart + 85 * minute
        // A three-hour block that started an hour ago used to anchor on its visible midpoint.
        #expect(GuideAnchor.focused(start: now - 60 * minute, visibleStart: slotStart,
                                    now: now) == .live)
        // An odd-length segment that started earlier used to anchor behind the clock.
        #expect(GuideAnchor.focused(start: now - 5 * minute, visibleStart: now - 5 * minute,
                                    now: now) == .live)
    }

    @Test("moving onto a later program picks its start")
    func laterProgramPicksStart() {
        let now = slotStart + 10 * minute
        let start = slotStart + 30 * minute
        #expect(GuideAnchor.focused(start: start, visibleStart: slotStart, now: now) == .at(start))
    }

    @Test("a later block reaching in from the left picks the viewport's edge")
    func laterBlockClampsToViewport() {
        let now = slotStart
        let visible = slotStart + 240 * minute
        #expect(GuideAnchor.focused(start: slotStart + 180 * minute, visibleStart: visible,
                                    now: now) == .at(visible))
    }

    @Test("Now and Prime Time set the anchor and ask for a scroll")
    func jumpsSetTheAnchor() {
        let model = model(now: Date())
        model.anchor = .at(Date().addingTimeInterval(3600))
        let version = model.scrollRequestVersion
        model.jumpToNow()
        #expect(model.anchor == .live)
        #expect(model.scrollRequestVersion == version + 1)
        // The 48h axis always reaches tomorrow evening.
        #expect(model.jumpToPrimeTime(days: 1))
        #expect(model.anchor != .live)
    }
}
