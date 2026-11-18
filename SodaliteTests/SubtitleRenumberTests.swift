import Testing
import Foundation
@testable import Sodalite

/// Jellyfin renumbers the streams when a subtitle file is added or removed. The new stream is found by
/// what it is, not by an index that moved, and the active picks follow their streams. Audit 2026-11-17
/// PUI-202, PUI-203.
@MainActor
struct SubtitleRenumberTests {

    private func stream(_ index: Int, language: String, external: Bool, codec: String = "subrip",
                        title: String? = nil) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: language,
                    displayTitle: nil, title: title, isDefault: nil, isForced: nil,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    @Test func theNewStreamIsFoundWhenTheOldExternalOneMovesUp() {
        let before = [stream(5, language: "eng", external: true)]
        // German sorts first, so it takes 5 and English becomes 6.
        let after = [stream(5, language: "ger", external: true), stream(6, language: "eng", external: true)]
        let added = ExternalSubtitleSignature.newlyAttached(
            before: ExternalSubtitleSignature.externals(in: before), after: after)
        #expect(added?.language == "ger")
        #expect(added?.index == 5)
    }

    @Test func nothingIsNewWhenTheExternalsAreTheSame() {
        let streams = [stream(5, language: "eng", external: true)]
        #expect(ExternalSubtitleSignature.newlyAttached(
            before: ExternalSubtitleSignature.externals(in: streams), after: streams) == nil)
    }

    @Test func aSecondFileOfTheSameKindCountsAsNew() {
        let before = [stream(5, language: "eng", external: true)]
        let after = [stream(5, language: "eng", external: true), stream(6, language: "eng", external: true)]
        let added = ExternalSubtitleSignature.newlyAttached(
            before: ExternalSubtitleSignature.externals(in: before), after: after)
        #expect(added?.index == 6)
    }

    @Test func anActivePickFollowsItsStreamThroughARenumbering() {
        let old = [stream(2, language: "fre", external: false), stream(5, language: "eng", external: true)]
        let new = [stream(2, language: "fre", external: false),
                   stream(5, language: "ger", external: true), stream(6, language: "eng", external: true)]
        #expect(PlayerViewModel.remappedSubtitleIndex(5, old: old, new: new) == 6)
        #expect(PlayerViewModel.remappedSubtitleIndex(2, old: old, new: new) == 2)
    }

    @Test func aRemovedStreamHasNoIndexLeft() {
        let old = [stream(5, language: "eng", external: true)]
        #expect(PlayerViewModel.remappedSubtitleIndex(5, old: old, new: []) == nil)
        #expect(PlayerViewModel.remappedSubtitleIndex(nil, old: old, new: old) == nil)
    }

    @Test func deletingAnExternalRefreshesBothListsAndTheActiveEmbeddedPick() throws {
        let item = try JSONDecoder().decode(
            JellyfinItem.self, from: Data(#"{"Id":"m","Name":"m","Type":"Movie"}"#.utf8))
        let vm = PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: RecordingPlaybackService(), userID: "u",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.renumber.\(UUID())")!))
        let external = stream(3, language: "eng", external: true)
        let embedded = stream(4, language: "fre", external: false)
        vm.sourceMediaStreams = [external, embedded]
        vm.subtitleStreams = [external, embedded]
        vm.activeSubtitleIndex = 4
        // After the delete Jellyfin numbers the embedded track 3.
        let refreshed = [stream(3, language: "fre", external: false)]

        vm.adoptRefreshedMediaStreams(refreshed, removing: 3)

        #expect(vm.subtitleStreams.map(\.index) == [3])
        #expect(vm.sourceMediaStreams.map(\.index) == [3])
        #expect(vm.activeSubtitleIndex == 3)
        #expect(vm.embeddedEngineTrackID(3) == 3)
    }
}
