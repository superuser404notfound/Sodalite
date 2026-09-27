import Testing
import Foundation
import SwiftUI
import AetherEngine
@testable import Sodalite

/// Sodalite#104: the live rail is a block of wall clock, and everything else about it follows.
///
/// What it replaced, captured on a device, one line per second after a rewind. The playhead stays 11
/// to 16 s behind the live edge for the whole run, so the viewer has not moved relative to live at
/// all, and the knob still walks across half the rail in ten seconds:
///
///     t+1s   playhead=33235.72  window=33230.02...33251.02  drawn=0.271
///     t+5s   playhead=33239.82  window=33230.02...33251.02  drawn=0.467
///     t+6s   playhead=33240.82  window=33230.02...33257.02  drawn=0.400
///     t+10s  playhead=33244.92  window=33230.02...33257.02  drawn=0.552
///
/// The seekable range's LOWER bound is the moment the channel was tuned and never moves; its upper
/// bound follows the live edge. Both the numerator and the denominator of a position-within-the-range
/// fraction therefore grow at one second per second, so the fraction runs to 1 no matter where the
/// viewer is. Five minutes in, a viewer ten seconds behind live is drawn at 0.97.
///
/// A denominator that does not move is the answer, and the one a viewer can name is the programme on
/// air: its start and end are fixed, so the knob moves when time moves and at no other moment. Where
/// the channel has no guide data the block is a rolling window of the same width, which is the same
/// shape under a less meaningful name.
@Suite("The live rail is a block of wall clock (Sodalite#104)")
struct LiveRailGeometryTests {

    private let span = PlaybackPreferences.LiveBufferDepth.ninetyMinutes.seconds

    /// One hour of programme, with the live edge exactly half way through it.
    private let programStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var programEnd: Date { programStart.addingTimeInterval(3600) }
    private var edge: Date { programStart.addingTimeInterval(1800) }

    private func makeProgram(id: String, name: String, start: Date?, end: Date?) -> JellyfinProgram {
        JellyfinProgram(
            id: id, channelId: "c1", channelName: "One", name: name, overview: nil,
            startDate: start, endDate: end, genres: nil, imageTags: nil,
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil, isKids: nil, isSports: nil,
            seriesName: nil, parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    private var program: JellyfinProgram {
        makeProgram(id: "p1", name: "NFL Football", start: programStart, end: programEnd)
    }

    private func block(_ programs: [JellyfinProgram],
                       behind: Double = 0) -> PlayerViewModel.LiveRailBlock {
        PlayerViewModel.liveRailBlock(
            programs: programs,
            playheadWallClock: edge.addingTimeInterval(-behind),
            liveEdgeWallClock: edge,
            fallbackSpanSeconds: span)
    }

    // MARK: The defect this exists for

    @Test("a viewer who does not move is not drawn moving")
    func aStationaryViewerStaysPut() {
        // Ten ticks a second apart, each holding the same distance behind an edge that advances.
        let drawn = (0..<10).map { tick -> Float in
            let now = edge.addingTimeInterval(Double(tick))
            let b = PlayerViewModel.liveRailBlock(
                programs: [program], playheadWallClock: now.addingTimeInterval(-13),
                liveEdgeWallClock: now, fallbackSpanSeconds: span)
            return PlayerViewModel.liveRailGeometry(
                block: b, liveEdgeWallClock: now,
                behindLiveSeconds: 13, residentSeconds: 600).playhead
        }
        // Ten seconds of a one hour block, which is what ten seconds of wall clock should look like.
        // The old model walked 0.271 to 0.552 across exactly this run.
        #expect(Double(drawn.max()! - drawn.min()!) < 0.004)
    }

    @Test("the same rewind reads the same however long the channel has been on")
    func aRewindDoesNotDriftWithSessionAge() {
        let young = PlayerViewModel.liveRailGeometry(
            block: block([program], behind: 10), liveEdgeWallClock: edge,
            behindLiveSeconds: 10, residentSeconds: 15)
        let old = PlayerViewModel.liveRailGeometry(
            block: block([program], behind: 10), liveEdgeWallClock: edge,
            behindLiveSeconds: 10, residentSeconds: 3600)
        #expect(young.playhead == old.playhead)
        // Half an hour into an hour, ten seconds back.
        #expect(abs(Double(young.playhead) - (1790.0 / 3600.0)) < 0.001)
    }

    // MARK: The four zones

    @Test("what the session holds is the available region, not the scale")
    func theResidentPartIsDrawnSeparately() {
        // Twenty seconds after the tune, half an hour into the programme: the rail is an hour wide
        // and only the last fifteen seconds of it can be played.
        let g = PlayerViewModel.liveRailGeometry(
            block: block([program]), liveEdgeWallClock: edge,
            behindLiveSeconds: 0, residentSeconds: 15)
        #expect(abs(Double(g.availableFrom) - (1785.0 / 3600.0)) < 0.001)
        #expect(g.playhead == g.liveEdge)
        // A session older than the programme holds all of it.
        let mature = PlayerViewModel.liveRailGeometry(
            block: block([program]), liveEdgeWallClock: edge,
            behindLiveSeconds: 0, residentSeconds: 7200)
        #expect(mature.availableFrom == 0)
    }

    @Test("the live edge sits inside the block, not at the end of it")
    func theEdgeIsAPlaceInTheBlock() {
        let g = PlayerViewModel.liveRailGeometry(
            block: block([program]), liveEdgeWallClock: edge,
            behindLiveSeconds: 0, residentSeconds: 600)
        #expect(abs(Double(g.liveEdge) - 0.5) < 0.001)
        // Half the rail is programme that has not aired, which is the point of drawing the block.
        #expect(g.liveEdge < 1)
    }

    @Test("a rewind past what is held is clamped onto the rail, not off it")
    func aPositionBelowTheBlockClamps() {
        let g = PlayerViewModel.liveRailGeometry(
            block: block([program]), liveEdgeWallClock: edge,
            behindLiveSeconds: 3600, residentSeconds: 3600)
        #expect(g.playhead == 0)
    }

    // MARK: Which block

    @Test("a timeshifted viewer is inside the programme they are watching")
    func theBlockFollowsThePlayhead() {
        let earlier = makeProgram(id: "p0", name: "The Pregame",
                                  start: programStart.addingTimeInterval(-3600), end: programStart)
        // Half an hour into the football, watching live.
        #expect(block([earlier, program]).program?.id == "p1")
        // The same session rewound forty minutes is inside the previous programme, and the rail
        // frames that one instead.
        #expect(block([earlier, program], behind: 2400).program?.id == "p0")
    }

    @Test("a channel with no guide gets a rolling window ending at the edge")
    func theFallbackIsTheRollingWindow() {
        let b = block([])
        #expect(b.program == nil)
        #expect(b.end == edge)
        #expect(abs(b.seconds - span) < 0.001)
        // Which is the fixed-span rail: ten seconds behind is ten seconds from the right end.
        let g = PlayerViewModel.liveRailGeometry(
            block: b, liveEdgeWallClock: edge, behindLiveSeconds: 10, residentSeconds: span)
        #expect(abs(Double(g.playhead) - (1 - 10.0 / span)) < 0.001)
        #expect(g.liveEdge == 1)
    }

    @Test("a programme with no dates is not a block")
    func adatelessProgrammeFallsBack() {
        #expect(block([makeProgram(id: "p2", name: "Unknown", start: nil, end: nil)]).program == nil)
    }

    // MARK: Aiming along the rail

    @Test("a scrub maps across the block, so pressing and drawing agree")
    func scrubTargetsUseTheSameBlock() {
        let b = block([program])
        let seekable: ClosedRange<Double> = 33_000...34_800
        // The middle of this block is the live edge, which is the session's own upper bound.
        #expect(abs(PlayerViewModel.liveScrubTarget(
            scrubProgress: 0.5, block: b, liveEdgeWallClock: edge, seekable: seekable) - 34_800) < 0.001)
        // A quarter in is fifteen minutes before the edge, and this session holds half an hour, so
        // it maps to the second it names.
        #expect(abs(PlayerViewModel.liveScrubTarget(
            scrubProgress: 0.25, block: b, liveEdgeWallClock: edge, seekable: seekable) - 33_900) < 0.01)
        // The same aim on a session that has only been on for five minutes clamps onto what can be
        // played rather than off the rail.
        #expect(PlayerViewModel.liveScrubTarget(
            scrubProgress: 0.25, block: b, liveEdgeWallClock: edge,
            seekable: 34_500...34_800) == 34_500)
        // A position the session does hold maps to the second it names.
        #expect(abs(PlayerViewModel.liveScrubTarget(
            scrubProgress: Float(1790.0 / 3600.0), block: b, liveEdgeWallClock: edge,
            seekable: seekable) - 34_790) < 0.01)
    }

    @Test("the return-to-live affordance is the edge, not the end of the rail")
    func theSnapAsksAboutTheEdge() {
        let g = PlayerViewModel.liveRailGeometry(
            block: block([program]), liveEdgeWallClock: edge,
            behindLiveSeconds: 0, residentSeconds: 600)
        // Aiming into the part of the programme that has not aired is a return to live, because
        // there is nothing else there to aim at.
        #expect(PlayerViewModel.liveScrubReachedLiveEdge(scrubProgress: 1, liveEdge: g.liveEdge))
        #expect(PlayerViewModel.liveScrubReachedLiveEdge(scrubProgress: g.liveEdge,
                                                         liveEdge: g.liveEdge))
        // A rewind inside the block is not.
        #expect(!PlayerViewModel.liveScrubReachedLiveEdge(scrubProgress: 0.4, liveEdge: g.liveEdge))
        // On a rolling-window rail the edge IS the right end, which is the old rule intact.
        #expect(PlayerViewModel.liveScrubReachedLiveEdge(scrubProgress: 1, liveEdge: 1))
        #expect(!PlayerViewModel.liveScrubReachedLiveEdge(scrubProgress: 0.995, liveEdge: 1))
    }

    @Test("a ten second rewind is a rewind, whatever the block")
    func aShortRewindIsARewind() {
        // What the old 1%-of-the-window rule swallowed whole on a deep DVR window. Against a block a
        // press is a distance, and it is nowhere near the edge.
        let g = PlayerViewModel.liveRailGeometry(
            block: block([program], behind: 10), liveEdgeWallClock: edge,
            behindLiveSeconds: 10, residentSeconds: 600)
        #expect(!PlayerViewModel.liveScrubReachedLiveEdge(scrubProgress: g.playhead,
                                                          liveEdge: g.liveEdge))
    }
}

/// Sodalite#104: the iOS bar printed `-00:00` next to a thirty second rewind, because it was reading
/// a VOD remaining time on a session that has no duration. A live transport prints the distance from
/// the live edge instead, and both platforms format it here.
@Suite("A live transport prints a distance from live (Sodalite#104)")
struct LiveTransportLabelTests {

    @Test("a rewind reads as the offset it moved")
    func aRewindReadsAsItsOffset() {
        #expect(PlayerViewModel.liveBehindLabel(seconds: 30) == "-0:30")
        #expect(PlayerViewModel.liveBehindLabel(seconds: 95) == "-1:35")
        #expect(PlayerViewModel.liveBehindLabel(seconds: 600) == "-10:00")
    }

    @Test("the edge itself is not drawn as a negative offset")
    func theEdgeIsNotNegative() {
        #expect(PlayerViewModel.liveBehindLabel(seconds: 0) == "-0:00")
        // The engine's behind-live figure can cross zero by a fraction between two cuts.
        #expect(PlayerViewModel.liveBehindLabel(seconds: -2) == "-0:00")
    }

    /// At the edge this slot used to print the word LIVE, which the badge at the other end of the
    /// same row was already saying. On the phone the two sit close enough together to read as a
    /// stutter. The badge keeps the word; this slot keeps a number in both states, because an empty
    /// one would walk the play button off centre every time the edge is crossed.
    @Test("the slot says something in both states, and never the badge's word")
    func theslotNeverRepeatsTheBadge() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let live = PlayerViewModel.livePositionLabel(
            isAtLiveEdge: true, behindLiveSeconds: 0, playheadWallClock: at)
        #expect(live == PlayerViewModel.clockLabel(for: at))
        #expect(!live.isEmpty)
        #expect(!live.localizedCaseInsensitiveContains("live"))
        // Behind it, the distance, which is the thing a viewer actually wants there.
        #expect(PlayerViewModel.livePositionLabel(
            isAtLiveEdge: false, behindLiveSeconds: 30, playheadWallClock: at) == "-0:30")
    }

    @Test("both bars format a wall clock the same way")
    func oneClockFormat() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // The rail's ends, the clock tracking the knob and the position slot all read this one
        // function, so a rail cannot print 17:43 beside a slot printing 5:43 PM.
        #expect(PlayerViewModel.clockLabel(for: at) == at.formatted(date: .omitted, time: .shortened))
    }
}

/// Sodalite#104: a live episode carries everything a stored one does, and the player showed one line.
///
/// `JellyfinItem(liveChannel:program:)` hard-coded `seriesName`, `parentIndexNumber` and
/// `indexNumber` to nil, so `PlayerTitleOverlay` took its single-line branch on every live session
/// while a recording of the very same episode took the two-line one.
@Suite("A live programme names its series and episode (Sodalite#104)")
struct LiveProgramMetadataTests {

    private func program(name: String, seriesName: String?, episodeTitle: String?,
                         season: Int?, episode: Int?) -> JellyfinProgram {
        JellyfinProgram(
            id: "p", channelId: "c", channelName: "One", name: name, overview: nil,
            startDate: nil, endDate: nil, genres: nil, imageTags: nil, isLive: nil, isNews: nil,
            isMovie: nil, isSeries: true, isKids: nil, isSports: nil, seriesName: seriesName,
            parentIndexNumber: season, indexNumber: episode, episodeTitle: episodeTitle,
            timerId: nil, seriesTimerId: nil)
    }

    private let channel = JellyfinChannel(id: "c", name: "Comedy One", channelNumber: "1",
                                          imageTags: nil, currentProgram: nil, userData: nil)

    /// What the three title surfaces draw, which is the outcome both issues are about. Asserted
    /// instead of the individual fields because Sodalite#159 moves a field (`seriesName` now falls
    /// back to the programme name) without moving the rendered line above it.
    private func lines(name: String, seriesName: String?, episodeTitle: String?,
                       season: Int?, episode: Int?) -> PlayerTitleLines {
        PlayerTitleLines(item: JellyfinItem(
            liveChannel: channel,
            program: program(name: name, seriesName: seriesName, episodeTitle: episodeTitle,
                             season: season, episode: episode)))
    }

    @Test("an episode reaches the overlay as a series and an episode")
    func anEpisodeCarriesItsNumbers() {
        let item = JellyfinItem(liveChannel: channel,
                                program: program(name: "Friends", seriesName: "Friends",
                                                 episodeTitle: "The One With the Ball",
                                                 season: 3, episode: 15))
        #expect(item.seriesName == "Friends")
        #expect(item.parentIndexNumber == 3)
        #expect(item.indexNumber == 15)
        #expect(item.name == "The One With the Ball")
        let lines = PlayerTitleLines(item: item)
        #expect(lines.header == "Friends")
        #expect(lines.subtitle == "S3, E15 · The One With the Ball")
    }

    @Test("a title that just repeats the series name is dropped from the line under it")
    func arepeatedTitleIsNotDrawnTwice() {
        let lines = lines(name: "Friends", seriesName: "Friends", episodeTitle: nil,
                          season: 3, episode: 15)
        #expect(lines.header == "Friends")
        #expect(lines.subtitle == "S3, E15")
    }

    @Test("half a numbering is no numbering")
    func alonelySeasonIsDropped() {
        let item = JellyfinItem(liveChannel: channel,
                                program: program(name: "Nature", seriesName: "Nature",
                                                 episodeTitle: nil, season: 4, episode: nil))
        #expect(item.parentIndexNumber == nil)
        #expect(item.indexNumber == nil)
        #expect(PlayerTitleLines(item: item).subtitle == nil)
    }

    @Test("a programme that is not an episode still reads as itself")
    func aplainProgrammeIsUnchanged() {
        // Sodalite#159 gives `seriesName` the programme name, so the assertion moved off the field
        // and onto the line: the header is still the programme, and the subtitle, which would now
        // repeat it verbatim, is still dropped.
        let lines = lines(name: "Evening News", seriesName: nil, episodeTitle: nil,
                          season: nil, episode: nil)
        #expect(lines.header == "Evening News")
        #expect(lines.subtitle == nil)
        // And a channel with no guide entry at all keeps the channel's own name.
        let bare = PlayerTitleLines(item: JellyfinItem(liveChannel: channel, program: nil))
        #expect(bare.header == "Comedy One")
        #expect(bare.subtitle == nil)
    }

    @Test("a programme with an episode but no series leads with the programme (Sodalite#159)")
    func aseriesLessEpisodeKeepsItsProgrammeName() {
        // NOVA: the EPG names the programme and the episode, and no series at all. `name` is the
        // episode title by then, so without the fallback the programme name was simply gone.
        let lines = lines(name: "NOVA", seriesName: nil, episodeTitle: "Chasing Carbon",
                          season: 52, episode: 3)
        #expect(lines.header == "NOVA")
        #expect(lines.subtitle == "S52, E3 · Chasing Carbon")
    }

    @Test("a sports broadcast leads with the programme, not the fixture (Sodalite#159)")
    func asportsBroadcastNamesItsProgramme() {
        let lines = lines(name: "NFL Football", seriesName: nil,
                          episodeTitle: "Eagles at Cowboys", season: nil, episode: nil)
        #expect(lines.header == "NFL Football")
        #expect(lines.subtitle == "Eagles at Cowboys")
    }

    @Test("a named series still wins the header over the programme name (Sodalite#159)")
    func anamedSeriesOutranksTheProgrammeName() {
        let lines = lines(name: "NOVA", seriesName: "NOVA Science", episodeTitle: "Chasing Carbon",
                          season: 52, episode: 3)
        #expect(lines.header == "NOVA Science")
        #expect(lines.subtitle == "S52, E3 · Chasing Carbon")
    }

    private func decodedProgram(_ fields: String) throws -> JellyfinProgram {
        let json = "{\"Id\":\"p\",\"Name\":\"Heat\",\(fields)}"
        return try JSONDecoder().decode(JellyfinProgram.self, from: Data(json.utf8))
    }

    @Test("a live movie reads name over year, like a stored one (Sodalite#159)")
    func aliveMovieCarriesItsYear() throws {
        let program = try decodedProgram("\"IsMovie\":true,\"ProductionYear\":1995")
        let lines = PlayerTitleLines(item: JellyfinItem(liveChannel: channel, program: program))
        #expect(lines.header == "Heat")
        #expect(lines.subtitle == "1995")
        #expect(program.identityLabel == "1995")
    }

    @Test("the year of anything but a movie is an air date and stays off screen (Sodalite#159)")
    func anonMovieYearIsIgnored() throws {
        let program = try decodedProgram("\"IsSeries\":true,\"ProductionYear\":2024")
        let lines = PlayerTitleLines(item: JellyfinItem(liveChannel: channel, program: program))
        #expect(lines.header == "Heat")
        #expect(lines.subtitle == nil)
        #expect(program.identityLabel == nil)
    }

    @Test("a movie with no year in the guide still reads as itself (Sodalite#159)")
    func amovieWithoutAYearIsOneLine() throws {
        let program = try decodedProgram("\"IsMovie\":true")
        let lines = PlayerTitleLines(item: JellyfinItem(liveChannel: channel, program: program))
        #expect(lines.header == "Heat")
        #expect(lines.subtitle == nil)
    }
}

/// Sodalite#159: the player draws its title on three surfaces, and only one of them ran the second
/// line through `EpisodeMetadataFormatter`. The iOS touch controls and the AirPlay backdrop took
/// `item.name` raw, so a header and a subtitle holding the same string were drawn twice, which the
/// live fallback above makes reachable on every plain programme.
@Suite("One cascade for all three title surfaces (Sodalite#159)")
struct PlayerTitleLinesTests {

    /// Stored media, so the item comes off a decoded server row rather than the live adapter.
    private func lines(_ fields: String...) throws -> PlayerTitleLines {
        let json = "{\"Id\":\"i\",\"Type\":\"Episode\",\(fields.joined(separator: ","))}"
        return PlayerTitleLines(item: try JSONDecoder().decode(JellyfinItem.self,
                                                               from: Data(json.utf8)))
    }

    @Test("a stored episode reads series over episode identity")
    func astoredEpisodeIsUnchanged() throws {
        let lines = try lines("\"Name\":\"The One With the Ball\"", "\"SeriesName\":\"Friends\"",
                              "\"ParentIndexNumber\":3", "\"IndexNumber\":15")
        #expect(lines.header == "Friends")
        #expect(lines.subtitle == "S3, E15 · The One With the Ball")
    }

    @Test("a film reads its name over its year")
    func afilmKeepsItsYear() throws {
        let lines = try lines("\"Name\":\"Heat\"", "\"ProductionYear\":1995")
        #expect(lines.header == "Heat")
        #expect(lines.subtitle == "1995")
    }

    @Test("a subtitle that repeats the header is not drawn")
    func arepeatedLineIsDropped() throws {
        let lines = try lines("\"Name\":\"Evening News\"", "\"SeriesName\":\"Evening News\"")
        #expect(lines.header == "Evening News")
        #expect(lines.subtitle == nil)
    }
}

/// Sodalite#104: left and right on the d-pad already did two different things, and the bar drew them
/// identically. A press is a discrete step whose destination is known before it lands; a hold is a
/// scan ramping 15x to 240x that you stop when the picture looks right, and nothing about it is
/// countable, so a fixed-interval glyph over it would be a lie.
@Suite("The two seek gestures speak two languages (Sodalite#104)")
struct SeekReadoutTests {

    @Test("a burst of presses counts itself")
    func abursCounts() {
        var readout: SeekReadout = .press(seconds: 10, count: 1, direction: -1)
        // Three more presses of the same interval, the same way.
        for expected in 2...4 {
            readout = SeekReadout.press(seconds: 10, count: expected, direction: -1)
            #expect(readout == .press(seconds: 10, count: expected, direction: -1))
        }
        #expect(readout.direction == -1)
    }

    @Test("the side of travel is what puts the glyph beside the clock")
    func directionIsCarried() {
        #expect(SeekReadout.press(seconds: 30, count: 1, direction: 1).direction == 1)
        #expect(SeekReadout.hold(rate: 96, direction: -1).direction == -1)
    }

    @Test("a hold names a rate, and a press never does")
    func thetwoAreNotTheSameShape() {
        #expect(SeekReadout.hold(rate: 96, direction: 1) != SeekReadout.press(seconds: 96, count: 1, direction: 1))
        // The rate the continuous scan ramps through, which has no countable step in it.
        for held in stride(from: 0.0, through: 10.0, by: 0.5) {
            let rate = min(15 + held * 26, 240)
            #expect(rate >= 15 && rate <= 240)
        }
    }

    @Test("every skip interval the settings offer has a glyph to draw it with")
    func everyIntervalHasASymbol() {
        // SF Symbols ships goforward/gobackward at these steps only, and both the readout and the
        // touch HUD compose the name from the interval, so one without a glyph would render as a
        // blank box. Pinned against the shipped set rather than a copy of it.
        for interval in PlaybackPreferences.skipIntervalChoices {
            #expect(SkipGlyph.numbered.contains(interval))
            #expect(SkipGlyph.name(seconds: interval, direction: 1) == "goforward.\(interval)")
            #expect(SkipGlyph.name(seconds: interval, direction: -1) == "gobackward.\(interval)")
        }
    }

    @Test("a length with no numbered glyph falls back instead of drawing a blank box")
    func anUnknownLengthStillDraws() {
        #expect(SkipGlyph.name(seconds: 7, direction: 1) == "goforward")
        #expect(SkipGlyph.name(seconds: 7, direction: -1) == "gobackward")
    }
}

/// Sodalite#104: the scrim under the transport ramped linearly from fully transparent, which puts its
/// thinnest part exactly where the thin scrubber and the 0.6-opacity chips are drawn. On news and
/// sports that is where a score bug or a ticker sits.
@Suite("The control scrim is densest where the controls are (Sodalite#104)")
struct ControlScrimTests {

    @Test("the ramp is already half dark at its midpoint")
    func themidpointIsNotTransparent() {
        let stops = PlayerOverlayView.controlScrimStops
        #expect(stops.first?.location == 0)
        #expect(stops.last?.location == 1)
        // A linear ramp from clear would be at 0.44 of its final weight here; this one is at 0.51,
        // and the difference is the part the controls are read against.
        let mid = stops[1]
        #expect(mid.location == 0.45)
    }

    @Test("both platforms size the scrim from the player, not from two guesses")
    func theheightIsProportional() {
        // tvOS 1080 and a phone in landscape used to carry 300 and 260, which is the same intent
        // written twice.
        #expect(abs(PlayerOverlayView.controlScrimHeight(playerHeight: 1080) - 367.2) < 0.001)
        #expect(PlayerOverlayView.controlScrimHeight(playerHeight: 390)
                < PlayerOverlayView.controlScrimHeight(playerHeight: 1080))
        // The title scrim stays the lighter of the two, or the frame reads top-heavy instead.
        #expect(PlayerOverlayView.titleScrimHeight(playerHeight: 1080)
                < PlayerOverlayView.controlScrimHeight(playerHeight: 1080))
    }
}

/// Sodalite#104: the quarter-hour marks sit on the WALL clock, not on the block's own length.
///
/// A programme that starts at 20:15 has its marks at 20:30 and 20:45, which is where a viewer reading
/// a clock expects them; marks at even fractions of the block would land at 20:30 only by accident.
/// Both transports draw these from the same block, so the phone and the television cannot disagree
/// about where a quarter past is.
@Suite("The rail is marked on the clock, not on the block (Sodalite#104)")
struct LiveRailMarksTests {

    /// 20:15 to 21:15 on an arbitrary day.
    private func block(startMinute: Int, minutes: Double) -> PlayerViewModel.LiveRailBlock {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Round down to the hour, then add the offset, so the fixture sits on a real clock boundary.
        let hour = (start.timeIntervalSinceReferenceDate / 3600).rounded(.down) * 3600
        let from = Date(timeIntervalSinceReferenceDate: hour + Double(startMinute) * 60)
        return PlayerViewModel.LiveRailBlock(
            start: from, end: from.addingTimeInterval(minutes * 60), program: nil)
    }

    @Test("an hour that starts at a quarter past is marked at the three quarters inside it")
    func marksFollowTheClock() {
        let marks = block(startMinute: 15, minutes: 60).quarterHourFractions
        #expect(marks.count == 3)
        // 15 minutes in, 30 in, 45 in: a quarter, a half and three quarters of the hour.
        for (index, mark) in marks.enumerated() {
            #expect(abs(mark - Double(index + 1) * 0.25) < 0.001)
        }
    }

    @Test("a mark on either end of the block is not drawn on top of the rail label")
    func theendsAreLeftAlone() {
        // An hour starting exactly on the hour has marks at 0, 15, 30, 45 and 60 minutes; the two
        // that coincide with the rail's own ends are dropped.
        let marks = block(startMinute: 0, minutes: 60).quarterHourFractions
        #expect(marks.count == 3)
        #expect(marks.allSatisfy { $0 > 0 && $0 < 1 })
    }

    @Test("a short programme carries fewer marks")
    func thecountFollowsTheSpan() {
        // 20:20 to 20:40 crosses the half hour and nothing else.
        #expect(block(startMinute: 20, minutes: 20).quarterHourFractions.count == 1)
        // 20:20 to 20:30 crosses nothing: the half hour is its own right end, where the rail label
        // already says what a mark would.
        #expect(block(startMinute: 20, minutes: 10).quarterHourFractions.isEmpty)
        #expect(block(startMinute: 0, minutes: 5).quarterHourFractions.isEmpty)
    }

    @Test("an absurd block is not marked at all rather than marked a thousand times")
    func aday_longBlockIsNotMarked() {
        #expect(block(startMinute: 0, minutes: 24 * 60).quarterHourFractions.isEmpty)
        #expect(block(startMinute: 0, minutes: 0).quarterHourFractions.isEmpty)
    }
}

/// Sodalite#104: what follows the block, counted toward the rail that marks its end.
@Suite("The next-up line counts toward the end of the block (Sodalite#104)")
struct LiveNextUpTests {

    @Test("a programme still to come is named with how long until it starts")
    func aprogrammeIsCounted() {
        // Spelled like every duration in the app, which past an hour is hours AND minutes rather
        // than a hundred-odd minutes ("In 1h 41m: The OT", Sodalite#165).
        let text = LiveNextUpLine.text(name: "The OT", startsIn: 101 * 60)
        #expect(text.contains("The OT"))
        #expect(text.contains("1"))
        #expect(text.contains("41"))
    }

    @Test("the last minute of the countdown reads one minute, never zero")
    func aboutToStartCountsItsLastMinute() {
        let text = LiveNextUpLine.text(name: "The OT", startsIn: 20)
        #expect(text.contains("The OT"))
        #expect(text.contains("1") && !text.contains("0"))
    }

    @Test("a programme that has started is named without a number")
    func startedIsNamedWithoutANumber() {
        for seconds: TimeInterval in [0, -5] {
            let text = LiveNextUpLine.text(name: "The OT", startsIn: seconds)
            #expect(text.contains("The OT"))
            let hasDigit = text.contains { $0.isNumber }
            #expect(!hasDigit, "\(text)")
        }
    }
}

/// Sodalite#104: the rail spent the first minutes of every session on its no-guide fallback while the
/// title overlay above it already named the programme.
///
/// Reported from a device: a rail labelled 3:27 to 4:57 under a title reading "Loudenvielle,
/// Highlights". Those two clocks are not a programme, they are the rolling window wearing one's
/// clothes: ninety minutes of buffer depth ending at "now", to the minute. The session is launched
/// with the programme on air, and only the guide FETCH filled the window the rail read, and that
/// fetch waited behind the follower's first sleep.
@Suite("The rail reads the programme the session was launched with (Sodalite#104)")
struct LiveRailProgramSourceTests {

    private func program(_ id: String) -> JellyfinProgram {
        JellyfinProgram(
            id: id, channelId: "c", channelName: "One", name: "Loudenvielle, Highlights",
            overview: nil, startDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
            endDate: Date(timeIntervalSinceReferenceDate: 800_005_400), genres: nil, imageTags: nil,
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil, isKids: nil, isSports: nil,
            seriesName: nil, parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    @Test("the launch programme carries the rail until the guide fetch lands")
    func thelaunchProgrammeIsUsed() {
        let launched = program("on-air")
        #expect(PlayerViewModel.railPrograms(window: [], launched: launched).map(\.id) == ["on-air"])
    }

    @Test("the fetched window supersedes it, because it knows what comes before and after")
    func thefetchedWindowWins() {
        let fetched = [program("previous"), program("on-air"), program("next")]
        #expect(PlayerViewModel.railPrograms(window: fetched, launched: program("on-air")).count == 3)
    }

    @Test("a channel with no guide at all still has nothing, and falls back as it should")
    func nothingIsStillNothing() {
        #expect(PlayerViewModel.railPrograms(window: [], launched: nil).isEmpty)
    }
}

/// Sodalite#104: a pause longer than the DVR depth costs the viewer the stretch the sliding window
/// took while they were away, and the engine's clamp moves the resume into what is still held.
///
/// Measured on the harness with a 30 s window and a 70 s pause: the playhead sat at 93881.2 while the
/// window slid to 93890.0...93920.0 underneath it, and the resume landed at 93895.0. The clamp is
/// right; it was silent, and a viewer who paused a match saw it continue somewhere else with nothing
/// on screen to say why.
@Suite("A pause that outlived the buffer says so (Sodalite#104)")
struct LiveResumeClampNoticeTests {

    @Test("the sentence names what the viewer lost, not where the playhead went")
    func thesentenceNamesTheLoss() {
        let text = PlayerViewModel.liveResumeClampedNotice(skippedSeconds: 125)
        // Two minutes, spelled the way the locale spells a duration.
        #expect(text.contains("2"))
        // The position is on the rail already and the badge says whether it is live, so the sentence
        // does not repeat either.
        #expect(!text.localizedCaseInsensitiveContains("live edge"))
    }

    @Test("a clamp of under a second is not worth a sentence")
    func atinyClampIsSilent() {
        // The engine clamps with a margin, so a resume barely outside the window moves by a fraction.
        // Saying "0 seconds were not recorded" would be worse than saying nothing.
        let clamp = LiveResumeClamp(skippedSeconds: 0.4, behindLiveSeconds: 29)
        #expect(clamp.skippedSeconds < 1)
    }

    @Test("the harness capture produces a sentence with the right number in it")
    func thefieldCaptureReadsCorrectly() {
        // playhead 93881.16, clamp target 93895.0: fourteen seconds the window took.
        let clamp = LiveResumeClamp(skippedSeconds: 93895.0 - 93881.16, behindLiveSeconds: 24.99)
        #expect(clamp.skippedSeconds >= 1)
        #expect(PlayerViewModel.liveResumeClampedNotice(
            skippedSeconds: clamp.skippedSeconds).contains("14"))
    }
}
