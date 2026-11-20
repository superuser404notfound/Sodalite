import Foundation

/// Which button presses change the live channel (Sodalite#173). Up and Down zap only while nothing else
/// owns them and the bar is hidden (they pass through while it is visible); only the page keys, which
/// mean nothing else on a TV remote, zap over the bar. Swipes never reach this: the pan path calls the
/// host's navigate handlers directly.
enum LiveZapInput {
    enum Key { case up, down, pageUp, pageDown }
    enum Action: Equatable { case zap(Int), wake, passThrough, ignore }

    /// Remote silence after which an Up or Down press only wakes: a Siri Remote that has gone to sleep
    /// still delivers the press that wakes it, and that press changed the channel (Sodalite#173). The
    /// page keys come from TV remotes, which have nothing to wake.
    static let wakeIdle: TimeInterval = 60

    static func action(for key: Key, isLive: Bool, showControls: Bool,
                       errorVisible: Bool, overlayCapturesInput: Bool, remoteIdle: TimeInterval) -> Action {
        let isPage = key == .pageUp || key == .pageDown
        let delta = (key == .up || key == .pageUp) ? 1 : -1
        guard isLive, !overlayCapturesInput else { return isPage ? .ignore : .passThrough }
        if isPage { return .zap(delta) }
        guard errorVisible || !showControls else { return .passThrough }
        return remoteIdle >= wakeIdle ? .wake : .zap(delta)
    }
}
