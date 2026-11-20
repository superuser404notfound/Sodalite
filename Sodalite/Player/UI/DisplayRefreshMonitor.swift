import Combine
import QuartzCore
#if os(tvOS)
import UIKit
#endif

/// The refresh rate the panel is running right now, for the Stats for Nerds video section (Sodalite#239).
///
/// tvOS has no read-back of the HDMI mode a Match Frame Rate switch landed on, and
/// `UIScreen.maximumFramesPerSecond` reports what the screen can do, not what it does. Display-link ticks
/// follow the active mode, so they are the reading. A single tick's duration cannot tell 59.94 from 60,
/// hence the average over a couple of seconds.
///
/// tvOS only. On an iPhone, iPad or Mac the panel's rate under the video is the system's business
/// (ProMotion, adaptive sync), and a display link of our own would report its own cadence, not the
/// one the video gets.
@MainActor
final class DisplayRefreshMonitor: NSObject, ObservableObject {
    /// nil until a full second of ticks has been timed, and again right after a mode switch.
    @Published private(set) var refreshRate: Double?

    private var link: CADisplayLink?
    private var window = RefreshWindow()
    private var lastPublish: CFTimeInterval = 0

    func start() {
        #if os(tvOS)
        guard link == nil else { return }
        let screen = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }.first?.screen
        guard let link = screen?.displayLink(withTarget: self, selector: #selector(tick(_:))) else { return }
        link.add(to: .main, forMode: .common)
        self.link = link
        #endif
    }

    func stop() {
        link?.invalidate()
        link = nil
        window = RefreshWindow()
        refreshRate = nil
    }

    #if os(tvOS)
    @objc private func tick(_ link: CADisplayLink) {
        window.add(timestamp: link.timestamp, frameDuration: link.targetTimestamp - link.timestamp)
        // Republish at most once a second, the panel's own rate would re-render the overlay 60 times a second.
        guard link.timestamp - lastPublish >= 1 else { return }
        lastPublish = link.timestamp
        let rate = window.rate
        if rate != refreshRate { refreshRate = rate }
    }
    #endif
}

/// Rolling average of display-link intervals. Pure so the edge cases (a skipped tick, a mode switch) are testable.
struct RefreshWindow {
    /// How much history the average covers. Long enough that 59.94 and 60 come apart cleanly.
    static let span: Double = 3
    static let minimumSpan: Double = 1

    private var intervals: [(frames: Int, seconds: Double)] = []
    private var lastTimestamp: Double?
    private var frameDuration: Double = 0

    var rate: Double? {
        let seconds = intervals.reduce(0) { $0 + $1.seconds }
        guard seconds >= Self.minimumSpan else { return nil }
        return Double(intervals.reduce(0) { $0 + $1.frames }) / seconds
    }

    mutating func add(timestamp: Double, frameDuration duration: Double) {
        guard duration > 0 else { return }
        // A different mode: the old history describes the old rate, and averaged in it would show neither.
        if frameDuration > 0, abs(duration - frameDuration) / frameDuration > 0.01 {
            intervals.removeAll()
            lastTimestamp = nil
        }
        frameDuration = duration
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp, timestamp > last else { return }
        let seconds = timestamp - last
        // A busy main thread skips ticks; the gap is still a whole number of refreshes, so count them.
        let frames = max(1, Int((seconds / duration).rounded()))
        intervals.append((frames, seconds))
        var total = intervals.reduce(0) { $0 + $1.seconds }
        while total > Self.span, intervals.count > 1 {
            total -= intervals.removeFirst().seconds
        }
    }
}
