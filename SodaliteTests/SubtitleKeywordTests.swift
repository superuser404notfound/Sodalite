import Testing
import Foundation
@testable import Sodalite

/// One descriptor list and one bitmap predicate for the subtitle code. Audit 2026-11-17 PUI-R202, PCORE-R203.
@MainActor
struct SubtitleKeywordTests {

    private func stream(codec: String?, title: String? = nil) -> MediaStream {
        MediaStream(index: 0, type: .subtitle, codec: codec, language: "eng",
                    displayTitle: nil, title: title, isDefault: nil, isForced: nil,
                    isExternal: false, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    @Test func descriptorWordsMatchAsWholeWords() {
        #expect(TrackDisplayFormatter.hasSubtitleDescriptor("English [CC]"))
        #expect(TrackDisplayFormatter.hasSubtitleDescriptor("Songs & Signs"))
        #expect(TrackDisplayFormatter.hasSubtitleDescriptor("Music"))
        #expect(!TrackDisplayFormatter.hasSubtitleDescriptor("Occitan"))
        #expect(!TrackDisplayFormatter.hasSubtitleDescriptor(nil))
    }

    @Test func aTitleWithOccitanIsNotRankedAsHearingImpaired() {
        let plain = stream(codec: "subrip", title: "Occitan")
        let sdh = stream(codec: "subrip", title: "English SDH")
        #expect(PlayerViewModel.subtitleAutoPickRank(plain) < PlayerViewModel.subtitleAutoPickRank(sdh))
    }

    @Test func oneBitmapPredicateKnowsEverySpelling() {
        for codec in ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvbsub", "dvb_sub", "dvb_subtitle",
                      "dvdsub", "dvd_sub", "dvd_subtitle", "vobsub", "xsub", "PGSSUB"] {
            #expect(PlayerViewModel.isBitmapSubtitle(stream(codec: codec)), "\(codec)")
        }
        for codec in ["subrip", "ass", "webvtt", "hdmv_text_subtitle", nil] {
            #expect(!PlayerViewModel.isBitmapSubtitle(stream(codec: codec)), "\(codec ?? "nil")")
        }
    }

    @Test func theRankAgreesWithThePredicateOnABareVobsub() {
        let text = stream(codec: "subrip")
        let bitmap = stream(codec: "vobsub")
        #expect(PlayerViewModel.subtitleAutoPickRank(bitmap) == PlayerViewModel.subtitleAutoPickRank(text) + 1)
    }

    @Test func leftAndRightReseatFocusOnARowThatNoLongerHoldsIt() {
        let order: [PlayerViewModel.ControlsFocus] = [.subtitleButton, .audioButton]
        #expect(PlayerViewModel.steppedTransportFocus(order: order, current: .progressBar, direction: 1) == .subtitleButton)
        #expect(PlayerViewModel.steppedTransportFocus(order: order, current: .subtitleButton, direction: 1) == .audioButton)
        #expect(PlayerViewModel.steppedTransportFocus(order: order, current: .audioButton, direction: 1) == nil)
        #expect(PlayerViewModel.steppedTransportFocus(order: [], current: .progressBar, direction: 1) == nil)
    }
}
