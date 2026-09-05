import Testing
@testable import Sodalite

#if os(tvOS)
/// Sodalite#115: the 1st-generation Siri Remote has one button under the whole glass surface, so a
/// click at the edge arrives as `.select` like any other. The only way to tell the two apart is the
/// touch position the GameController framework reports, and this is the rule that reads it.
@Suite("Siri Remote edge click")
struct SiriRemoteEdgeClickTests {
    @Test("a click near the middle is not an edge click")
    func centreIsNotAnEdge() {
        #expect(SiriRemoteEdgeClick.direction(x: 0, y: 0) == nil)
        #expect(SiriRemoteEdgeClick.direction(x: 0.4, y: 0) == nil)
        #expect(SiriRemoteEdgeClick.direction(x: -0.4, y: 0) == nil)
        // Top and bottom edge: vertical only, no horizontal intent.
        #expect(SiriRemoteEdgeClick.direction(x: 0, y: 0.9) == nil)
        #expect(SiriRemoteEdgeClick.direction(x: 0, y: -0.9) == nil)
    }

    @Test("the left and right edge resolve to a signed direction")
    func edgesResolve() {
        #expect(SiriRemoteEdgeClick.direction(x: -0.9, y: 0) == -1)
        #expect(SiriRemoteEdgeClick.direction(x: 0.9, y: 0) == 1)
        #expect(SiriRemoteEdgeClick.direction(x: -1, y: 0) == -1)
        #expect(SiriRemoteEdgeClick.direction(x: 1, y: 0) == 1)
    }

    /// The threshold is guessed, not measured (no 1st-gen remote here), so pin it rather than let a
    /// later retune move it silently. `edgeThreshold` itself counts as inside the edge band.
    @Test("the threshold is inclusive and sits where the constant says")
    func thresholdIsInclusive() {
        let t = SiriRemoteEdgeClick.edgeThreshold
        #expect(SiriRemoteEdgeClick.direction(x: t, y: 0) == 1)
        #expect(SiriRemoteEdgeClick.direction(x: -t, y: 0) == -1)
        #expect(SiriRemoteEdgeClick.direction(x: t.nextDown, y: 0) == nil)
        #expect(SiriRemoteEdgeClick.direction(x: (-t).nextUp, y: 0) == nil)
    }

    /// A thumb parked in a corner is past the horizontal threshold too. Without the dominance term a
    /// click meant for the top of the surface would seek, so the horizontal component has to win.
    @Test("a corner click needs the horizontal component to dominate")
    func cornersNeedDominance() {
        #expect(SiriRemoteEdgeClick.direction(x: 0.7, y: 0.9) == nil)
        #expect(SiriRemoteEdgeClick.direction(x: -0.7, y: -0.9) == nil)
        #expect(SiriRemoteEdgeClick.direction(x: 0.9, y: 0.7) == 1)
        #expect(SiriRemoteEdgeClick.direction(x: -0.9, y: 0.7) == -1)
        // Exactly diagonal is ambiguous, so it is not a seek.
        #expect(SiriRemoteEdgeClick.direction(x: 0.8, y: 0.8) == nil)
    }
}
#endif
