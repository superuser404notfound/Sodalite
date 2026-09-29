/// Which button presses change the live channel (Sodalite#173). Up and Down zap only while nothing else
/// owns them and the bar is hidden (they pass through while it is visible); only the page keys, which
/// mean nothing else on a TV remote, zap over the bar. Swipes never reach this: the pan path calls the
/// host's navigate handlers directly.
enum LiveZapInput {
    enum Key { case up, down, pageUp, pageDown }
    enum Action: Equatable { case zap(Int), passThrough, ignore }

    static func action(for key: Key, isLive: Bool, showControls: Bool,
                       errorVisible: Bool, overlayCapturesInput: Bool) -> Action {
        let isPage = key == .pageUp || key == .pageDown
        let delta = (key == .up || key == .pageUp) ? 1 : -1
        guard isLive, !overlayCapturesInput else { return isPage ? .ignore : .passThrough }
        if isPage || errorVisible || !showControls { return .zap(delta) }
        return .passThrough
    }
}
