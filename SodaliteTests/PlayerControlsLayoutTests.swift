import Testing
@testable import Sodalite

@Suite("Player controls layout")
struct PlayerControlsLayoutTests {
    @Test("defaults are the order the player shipped with, stats following the old switch")
    func defaults() {
        let off = PlayerControlsLayout.defaults()
        #expect(off.visibleControls(in: .transport)
                == [.restart, .episodes, .chapters, .audio, .subtitles, .quality, .speed, .picture, .pip])
        #expect(off.visibleControls(in: .live) == [.audio, .subtitles, .pip, .multiview])
        #expect(off.entries(in: .transport).last == .init(control: .stats, isVisible: false))
        let on = PlayerControlsLayout.defaults(showsStats: true)
        #expect(on.visibleControls(in: .transport).last == .stats)
        #expect(on.visibleControls(in: .live).last == .stats)
        #expect(on.visibleControls(in: .topBar) == [.rotationLock, .childLock, .airPlay])
        #expect(on.visibleControls(in: .gestures) == [.brightnessSwipe, .volumeSwipe])
    }

    @Test("hiding sinks a control below the visible ones, showing appends it to them")
    func toggleVisibility() {
        var layout = PlayerControlsLayout.defaults()
        layout.setVisible(false, .restart, in: .transport)
        #expect(layout.visibleControls(in: .transport).first == .episodes)
        #expect(layout.entries(in: .transport).filter { !$0.isVisible }.map(\.control) == [.restart, .stats])
        layout.setVisible(true, .restart, in: .transport)
        #expect(layout.visibleControls(in: .transport).last == .restart)
        #expect(layout.isVisible(.restart, in: .transport))
    }

    @Test("a group is independent of the others")
    func groupsIndependent() {
        var layout = PlayerControlsLayout.defaults(showsStats: true)
        layout.setVisible(false, .stats, in: .live)
        #expect(layout.isVisible(.stats, in: .transport))
        #expect(!layout.isVisible(.stats, in: .live))
    }

    @Test("move places a visible control among the visible ones")
    func move() {
        var layout = PlayerControlsLayout.defaults()
        layout.move(.subtitles, toVisibleIndex: 0, in: .transport)
        #expect(Array(layout.visibleControls(in: .transport).prefix(3)) == [.subtitles, .restart, .episodes])
        layout.move(.subtitles, toVisibleIndex: 99, in: .transport)
        #expect(layout.visibleControls(in: .transport).last == .subtitles)
        layout.move(.stats, toVisibleIndex: 0, in: .transport)
        #expect(!layout.isVisible(.stats, in: .transport))
    }

    @Test("a layout survives a round trip through storage")
    func roundTrip() {
        var layout = PlayerControlsLayout.defaults()
        layout.setVisible(false, .speed, in: .transport)
        layout.move(.chapters, toVisibleIndex: 0, in: .transport)
        layout.setVisible(false, .volumeSwipe, in: .gestures)
        #expect(PlayerControlsLayout.decoded(layout.encoded()) == layout)
    }

    @Test("decoding drops unknown and misplaced controls and appends missing ones")
    func lossyDecode() {
        let stored = #"{"transport":[{"control":"teleport","visible":true},{"control":"audio","visible":true},{"control":"airPlay","visible":true},{"control":"audio","visible":false}],"future":[]}"#
        let layout = PlayerControlsLayout.decoded(stored)
        let transport = layout.visibleControls(in: .transport)
        #expect(transport.first == .audio)
        #expect(!transport.contains(.airPlay))
        #expect(transport.filter { $0 == .audio }.count == 1)
        #expect(transport.contains(.restart))
        #expect(!layout.isVisible(.stats, in: .transport))
        #expect(layout.visibleControls(in: .live) == PlayerControlsLayout.defaults().visibleControls(in: .live))
    }

    @Test("restoring the defaults keeps each row's Stats as it was")
    func restoreKeepsStatsPerGroup() {
        var layout = PlayerControlsLayout.defaults()
        layout.setVisible(true, .stats, in: .live)
        layout.setVisible(false, .restart, in: .transport)
        layout.move(.audio, toVisibleIndex: 0, in: .live)
        let restored = layout.restoringDefaults()
        #expect(restored.isVisible(.restart, in: .transport))
        #expect(!restored.isVisible(.stats, in: .transport))
        #expect(restored.visibleControls(in: .live) == [.audio, .subtitles, .pip, .multiview, .stats])
    }

    @Test("garbage falls back to the defaults")
    func garbage() {
        #expect(PlayerControlsLayout.decoded("nope", showsStats: true) == .defaults(showsStats: true))
    }
}
