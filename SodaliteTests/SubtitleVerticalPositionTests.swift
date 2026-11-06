import Foundation
import Testing
@testable import Sodalite

@Suite("Subtitle vertical position steps")
struct SubtitleVerticalPositionTests {
    typealias Position = PlaybackPreferences.SubtitleVerticalPosition

    @Test("Stored raw values of the original steps never change")
    func legacyRawValuesStable() {
        for raw in ["default", "bottom", "step1", "step2", "step3"] {
            #expect(Position(rawValue: raw) != nil, "\(raw) must still decode")
        }
    }

    @Test("Fine steps fill the gap between Bottom Edge and Low (#229)")
    func edgeStepsBetweenBottomAndLow() {
        #expect(Position.edge2.fractionFromBottom == 0.02)
        #expect(Position.edge4.fractionFromBottom == 0.04)
        #expect(Position.edge6.fractionFromBottom == 0.06)
        #expect(Position.edge8.fractionFromBottom == 0.08)
    }

    @Test("Picker order rises strictly from the bottom up")
    func pickerOrderIsMonotonic() {
        let fractions = Position.allCases.dropFirst().compactMap(\.fractionFromBottom)
        #expect(Position.allCases.first == .default)
        #expect(fractions.count == Position.allCases.count - 1)
        #expect(fractions == fractions.sorted())
        #expect(Set(fractions).count == fractions.count)
    }

    @Test("Fine steps label as a percentage, named steps keep their words")
    func labels() {
        #expect(Position.edge4.label == 0.04.formatted(.percent.precision(.fractionLength(0))))
        #expect(Position.step1.label == String(localized: "settings.playback.subtitle.position.step1"))
    }
}
