import Foundation

/// Which multiview tile shows its info label and speaker glyph: only the focused one, from the moment
/// focus or sound arrives on it until `hold` after the last of those.
struct MultiviewOverlayVisibility: Equatable {
    static let hold: Duration = .seconds(3)

    private(set) var focused: UUID?
    private(set) var shown: UUID?
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var revision = 0

    func isVisible(_ id: UUID) -> Bool { shown == id }

    mutating func focusChanged(to id: UUID?, now: ContinuousClock.Instant) {
        focused = id
        shown = id
        deadline = id == nil ? nil : now.advanced(by: Self.hold)
        revision += 1
    }

    mutating func audioArrived(on id: UUID, now: ContinuousClock.Instant) {
        guard id == focused else { return }
        shown = id
        deadline = now.advanced(by: Self.hold)
        revision += 1
    }

    mutating func expire(now: ContinuousClock.Instant) {
        guard let deadline, deadline <= now else { return }
        shown = nil
        self.deadline = nil
    }
}
