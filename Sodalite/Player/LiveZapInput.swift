/// Which channel keys change the live channel (Sodalite#173). Up and Down only while nothing else owns
/// them; the channel keys of a TV remote mean nothing else, so they zap over the bar too.
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
