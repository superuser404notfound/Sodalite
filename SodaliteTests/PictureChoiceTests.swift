import Testing
import Foundation
import CoreGraphics
import AetherEngine
@testable import Sodalite

/// Sodalite#118: Fill zooms past bars painted into the frame, from a detected area or a picked ratio.
struct PictureChoiceTests {
    private let wide = 16.0 / 9.0
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let tv = CGSize(width: 1920, height: 1080)

    @Test("the menu lists Original, Auto and the four ratios in order")
    func allChoicesInOrder() {
        #expect(PictureChoice.all == [.original, .fill(.auto), .fill(.r4x3), .fill(.r185), .fill(.r200), .fill(.r239)])
    }

    @Test("a picked ratio is a centred pillar or band of that ratio")
    func ratioAreaPillarAndLetterbox() throws {
        let pillar = try #require(PictureChoice.fill(.r4x3).area(presentationAspect: wide, detected: nil))
        #expect(abs(pillar.width - 0.75) < 0.001)
        #expect(abs(pillar.midX - 0.5) < 0.001)
        #expect(pillar.height == 1)
        let band = try #require(PictureChoice.fill(.r239).area(presentationAspect: wide, detected: nil))
        #expect(abs(band.height - 0.7438) < 0.001)
        #expect(abs(band.midY - 0.5) < 0.001)
        #expect(band.width == 1)
    }

    @Test("Auto uses the detected area and falls back to the full frame")
    func autoFallsBackToFullFrame() {
        #expect(PictureChoice.fill(.auto).area(presentationAspect: wide, detected: nil) == full)
        let found = PictureArea(rect: CGRect(x: 0, y: 0.128, width: 1, height: 0.744), snappedRatio: 2.39)
        #expect(PictureChoice.fill(.auto).area(presentationAspect: wide, detected: found) == found.rect)
    }

    @Test("Original has no area")
    func originalHasNoArea() {
        #expect(PictureChoice.original.area(presentationAspect: wide, detected: nil) == nil)
    }

    @Test("only Auto greys out, and only once a scan says it would change nothing")
    func onlyAutoCanBeDisabled() {
        let finished = PictureChoice.isEnabled(.fill(.auto), presentationSize: tv, surface: tv,
                                               detected: .fullFrame, scanState: .finished)
        #expect(!finished)
        let unavailable = PictureChoice.isEnabled(.fill(.auto), presentationSize: tv, surface: tv,
                                                  detected: nil, scanState: .unavailable)
        #expect(!unavailable)
        let scanning = PictureChoice.isEnabled(.fill(.auto), presentationSize: tv, surface: tv,
                                               detected: nil, scanState: .scanning)
        #expect(scanning)
        let pillarboxed = PictureChoice.isEnabled(.fill(.auto), presentationSize: CGSize(width: 1440, height: 1080),
                                                  surface: tv, detected: .fullFrame, scanState: .finished)
        #expect(pillarboxed)
        let scope = PictureArea(rect: CGRect(x: 0, y: 0.128, width: 1, height: 0.744), snappedRatio: 2.39)
        #expect(PictureChoice.isEnabled(.fill(.auto), presentationSize: tv, surface: tv,
                                        detected: scope, scanState: .finished))
    }

    @Test("manual ratios and Original stay enabled")
    func manualRatiosAlwaysEnabled() {
        for choice in PictureChoice.all where choice != .fill(.auto) {
            #expect(PictureChoice.isEnabled(choice, presentationSize: tv, surface: tv,
                                            detected: .fullFrame, scanState: .finished))
        }
    }

    @Test("ratio labels read like a cinema ratio")
    func ratioLabels() {
        #expect(PictureChoice.ratioLabel(4.0 / 3.0) == "4:3")
        #expect(PictureChoice.ratioLabel(1.78) == "16:9")
        #expect(PictureChoice.ratioLabel(1.85) == "1.85:1")
        #expect(PictureChoice.ratioLabel(2.0) == "2.00:1")
        #expect(PictureChoice.ratioLabel(2.39) == "2.39:1")
    }

    @Test("titles compose the Fill word with Auto or the ratio")
    func titles() {
        let scope = PictureArea(rect: CGRect(x: 0, y: 0.128, width: 1, height: 0.744), snappedRatio: 2.39)
        #expect(PictureChoice.fill(.auto).fillTitle(fill: "Fill", auto: "Auto", detected: nil) == "Fill (Auto)")
        #expect(PictureChoice.fill(.auto).fillTitle(fill: "Fill", auto: "Auto", detected: scope) == "Fill (Auto, 2.39:1)")
        #expect(PictureChoice.fill(.auto).fillTitle(fill: "Fill", auto: "Auto", detected: .fullFrame) == "Fill (Auto)")
        #expect(PictureChoice.fill(.r185).fillTitle(fill: "Fill", auto: "Auto", detected: scope) == "Fill (1.85:1)")
    }
}
