import Testing
import Foundation
@testable import Sodalite

/// Sodalite#250: the audio and subtitle pick a detail page holds until Play. It belongs to one item
/// and is read against the version Play will start, which can change after the pick.
@MainActor
struct TrackPickSelectionTests {

    /// Version A: English TrueHD, German AC-3 5.1, two English PGS tracks that look alike.
    /// Version B: German AC-3 5.1 at another index, one English subtitle, no second language.
    private static let json = #"""
    {"Id":"e1","Name":"Pilot","Type":"Episode",
     "MediaSources":[
       {"Id":"src-a","Name":"Pilot [2160p]","Container":"mkv",
        "MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160},
          {"Index":1,"Type":"Audio","Codec":"truehd","Language":"eng","Channels":8},
          {"Index":2,"Type":"Audio","Codec":"ac3","Language":"ger","Channels":6},
          {"Index":3,"Type":"Subtitle","Codec":"PGSSUB","Language":"eng"},
          {"Index":4,"Type":"Subtitle","Codec":"subrip","Language":"eng","IsExternal":true}]},
       {"Id":"src-b","Name":"Pilot [720p]","Container":"mp4",
        "MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"h264","Width":1280,"Height":720},
          {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","Channels":2},
          {"Index":2,"Type":"Audio","Codec":"aac","Language":"jpn","Channels":2},
          {"Index":3,"Type":"Audio","Codec":"ac3","Language":"ger","Channels":6},
          {"Index":4,"Type":"Subtitle","Codec":"subrip","Language":"eng","IsExternal":true}]}
     ]}
    """#

    private func item(_ json: String = Self.json) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func source(_ id: String, in item: JellyfinItem) -> MediaSource {
        item.mediaSources!.first { $0.id == id }!
    }

    private func stream(_ index: Int, in source: MediaSource) -> MediaStream {
        source.mediaStreams!.first { $0.index == index }!
    }

    @Test func nothingPickedResolvesToNil() throws {
        let e1 = try item()
        #expect(TrackPickSelection().resolved(for: e1, source: source("src-a", in: e1)) == nil)
    }

    @Test func pickBelongsToItsItem() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseAudio(stream(2, in: a), item: e1, source: a)
        let e2 = try item(Self.json.replacingOccurrences(of: #""Id":"e1""#, with: #""Id":"e2""#))
        #expect(selection.resolved(for: e2, source: source("src-a", in: e2)) == nil)
    }

    @Test func sameSourceKeepsExactIndex() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseSubtitle(.stream(stream(4, in: a)), item: e1, source: a)
        selection.chooseAudio(stream(2, in: a), item: e1, source: a)
        let pick = try #require(selection.resolved(for: e1, source: a))
        #expect(pick.itemID == "e1")
        #expect(pick.sourceID == "src-a")
        #expect(pick.audio?.streamIndex == 2)
        guard case .track(let index, _) = pick.subtitle else { Issue.record("no subtitle"); return }
        #expect(index == 4)
    }

    @Test func otherSourceRematchesBySignature() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseAudio(stream(2, in: a), item: e1, source: a)
        let pick = try #require(selection.resolved(for: e1, source: source("src-b", in: e1)))
        #expect(pick.sourceID == "src-b")
        #expect(pick.audio?.streamIndex == 3)
    }

    @Test func otherSourceWithoutMatchFallsBackToAutomatic() throws {
        let e1 = try item()
        let b = source("src-b", in: e1)
        var selection = TrackPickSelection()
        selection.chooseAudio(stream(2, in: b), item: e1, source: b)
        #expect(selection.resolved(for: e1, source: source("src-a", in: e1)) == nil)
    }

    @Test func offSurvivesVersionSwitch() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseSubtitle(.off, item: e1, source: a)
        #expect(selection.resolved(for: e1, source: source("src-b", in: e1))?.subtitle == .off)
    }

    @Test func automaticClearsAnAxis() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseAudio(stream(2, in: a), item: e1, source: a)
        selection.chooseSubtitle(.off, item: e1, source: a)
        selection.chooseAudio(nil, item: e1, source: a)
        selection.chooseSubtitle(.automatic, item: e1, source: a)
        #expect(selection.resolved(for: e1, source: a) == nil)
    }

    @Test func aPickOnAnotherItemStartsOver() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        let e2 = try item(Self.json.replacingOccurrences(of: #""Id":"e1""#, with: #""Id":"e2""#))
        var selection = TrackPickSelection()
        selection.chooseSubtitle(.off, item: e1, source: a)
        selection.chooseAudio(stream(2, in: source("src-a", in: e2)), item: e2, source: source("src-a", in: e2))
        #expect(selection.resolved(for: e2, source: source("src-a", in: e2))?.subtitle == nil)
    }

    @Test func isOfferedRules() throws {
        func source(_ streams: String) throws -> MediaSource {
            try JSONDecoder().decode(MediaSource.self, from: Data(#"{"Id":"s","MediaStreams":[\#(streams)]}"#.utf8))
        }
        let video = #"{"Index":0,"Type":"Video","Codec":"h264"}"#
        let audio1 = #"{"Index":1,"Type":"Audio","Codec":"aac","Language":"eng"}"#
        let audio2 = #"{"Index":2,"Type":"Audio","Codec":"aac","Language":"ger"}"#
        let sub = #"{"Index":3,"Type":"Subtitle","Codec":"subrip","Language":"eng"}"#
        #expect(!TrackPickSelection.isOffered(for: try source("\(video),\(audio1)")))
        #expect(TrackPickSelection.isOffered(for: try source("\(video),\(audio1),\(audio2)")))
        #expect(TrackPickSelection.isOffered(for: try source("\(video),\(audio1),\(sub)")))
        #expect(!TrackPickSelection.isOffered(for: nil))
    }

    // MARK: - The pill's label

    /// The simulator's locale decides the words, so the expectations are built from the catalog and
    /// the locale's own language names rather than from English.
    private func language(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    @Test func pillSubtitleAutomatic() throws {
        let e1 = try item()
        #expect(TrackPickSelection().pillSubtitle(for: e1, source: source("src-a", in: e1)) == String(localized: "detail.tracks.automatic"))
    }

    @Test func pillSubtitleAudioOnly() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseAudio(stream(2, in: a), item: e1, source: a)
        #expect(selection.pillSubtitle(for: e1, source: a) == language("ger"))
    }

    @Test func pillSubtitleBoth() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseAudio(stream(2, in: a), item: e1, source: a)
        selection.chooseSubtitle(.stream(stream(3, in: a)), item: e1, source: a)
        #expect(selection.pillSubtitle(for: e1, source: a) == language("ger") + " · " + String(localized: "detail.tracks.subtitleSummary \(language("eng"))"))
    }

    @Test func pillSubtitleOff() throws {
        let e1 = try item()
        let a = source("src-a", in: e1)
        var selection = TrackPickSelection()
        selection.chooseSubtitle(.off, item: e1, source: a)
        #expect(selection.pillSubtitle(for: e1, source: a) == String(localized: "detail.tracks.subtitlesOff"))
    }
}
