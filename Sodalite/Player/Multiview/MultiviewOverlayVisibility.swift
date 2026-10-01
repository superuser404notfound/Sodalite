import Foundation

/// Which multiview tiles currently show their info label and speaker glyph. A tile is shown by a trigger
/// (focus arrived, sound arrived) and hidden `hold` after the last one.
struct MultiviewOverlayVisibility: Equatable {
    static let hold: Duration = .seconds(3)

    private(set) var deadlines: [UUID: ContinuousClock.Instant] = [:]
    private(set) var revision = 0

    func isVisible(_ id: UUID) -> Bool { deadlines[id] != nil }

    var nextDeadline: ContinuousClock.Instant? { deadlines.values.min() }

    mutating func show(_ id: UUID, now: ContinuousClock.Instant) {
        deadlines[id] = now.advanced(by: Self.hold)
        revision += 1
    }

    mutating func expire(now: ContinuousClock.Instant) {
        deadlines = deadlines.filter { $0.value > now }
    }
}
