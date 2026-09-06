import Testing
import UIKit
@testable import Sodalite

/// Sodalite#109 follow-up, reported on the shipped fix: the controls view had no air above the
/// artwork or below the progress bar, and dropping into the ambient view was a visible jump.
///
/// Both come out of one number. The tvOS Now Playing column carries the cover, the title block, the
/// transport row and the scrubber inside the 960pt title-safe band, and the old sizes added up to
/// 967pt with a one-line album title and 1033 with a wrapped one. There was no whitespace because
/// there was no room, and SwiftUI bought the missing room by taking the album title's second line
/// away. The travel is the same number seen from the other side: when the chrome leaves, the column
/// recentres by half of what left.
///
/// So this pins the budget rather than any single control's size. The font metrics are read at
/// runtime, since they are what the layout actually gets.
@MainActor
struct NowPlayingVerticalBudgetTests {

    private func lineHeight(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style).lineHeight
    }

    /// Transport row over scrubber track over time labels.
    private var chrome: CGFloat {
        NowPlayingMetrics.transportPrimary
            + NowPlayingMetrics.chromeSpacing
            + NowPlayingMetrics.scrubTrackHeight
            + NowPlayingMetrics.scrubLabelSpacing
            + lineHeight(.caption1)
    }

    /// Album title (one or two lines), track name, artist.
    private func metadata(titleLines: CGFloat) -> CGFloat {
        lineHeight(.title2) * titleLines
            + NowPlayingMetrics.metadataSpacing + lineHeight(.title3)
            + NowPlayingMetrics.metadataSpacing + lineHeight(.callout)
    }

    /// Beside the queue the title block lives in the OTHER column, so this one is cover over chrome.
    private var wideCoverColumn: CGFloat {
        NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + chrome
    }

    /// The same album once the chrome and the queue have gone: the title block has moved in here,
    /// and nothing is reserved behind the chrome because the title already filled the gap.
    private func ambientColumn(titleLines: CGFloat) -> CGFloat {
        NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + metadata(titleLines: titleLines)
    }

    /// A SINGLE-track album, the only case with no queue column to give the title block up to. The
    /// chrome leaves and nothing arrives, so half its height stays reserved.
    private func soloColumn(titleLines: CGFloat, chromeShown: Bool) -> CGFloat {
        NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + metadata(titleLines: titleLines)
            + NowPlayingMetrics.columnSpacing
            + (chromeShown ? chrome : chrome / 2)
    }

    private func margin(_ columnHeight: CGFloat) -> CGFloat {
        (NowPlayingMetrics.tvSafeBandHeight - columnHeight) / 2
    }

    // MARK: - The whitespace that was reported missing

    @Test("The controls view keeps real air above the cover and under the times")
    func oneLineTitleBreathes() {
        #expect(margin(soloColumn(titleLines: 1, chromeShown: true)) >= 40)
    }

    /// The common case, not the edge one: of nine sample album titles six wrapped at the old 560pt
    /// column width and four still wrap at 720. A wrapped title costs a whole title2 line, and it was
    /// that line the old budget could not pay, so the title was truncated to one instead.
    @Test("A wrapped album title still fits the band, with the second line intact")
    func wrappedTitleStillFits() {
        let column = soloColumn(titleLines: 2, chromeShown: true)

        #expect(column <= NowPlayingMetrics.tvSafeBandHeight)
        #expect(margin(column) >= 15)
    }

    @Test("The lone column is wider than the one beside the queue, which is what keeps titles unwrapped")
    func soloColumnIsTheWiderOne() {
        #expect(NowPlayingMetrics.soloColumnWidth > NowPlayingMetrics.wideColumnWidth)
    }

    // MARK: - The jump

    /// The transition the screen actually makes. The queue never leaves without the chrome and the
    /// chrome never leaves without the queue, so the old model here (solo column with chrome, then
    /// the same column without it) described a state an album with a queue never passes through, and
    /// it read 43pt while the screen was moving 97. Both columns are centred, so the travel is half
    /// the difference between them.
    @Test("The cover barely moves when the queue and the chrome leave")
    func coverTravelsLessThanAJump() {
        for titleLines: CGFloat in [1, 2] {
            let travel = abs(wideCoverColumn - ambientColumn(titleLines: titleLines)) / 2

            #expect(travel <= 50)
        }
    }

    /// A single-track album makes the other transition, and there the reserve is what keeps it small:
    /// without it the column loses the chrome's full height and the artwork drops 85pt.
    @Test("A single-track album settles rather than jumps when the chrome leaves")
    func singleTrackCoverTravelsLessThanAJump() {
        let travel = (soloColumn(titleLines: 1, chromeShown: true)
                      - soloColumn(titleLines: 1, chromeShown: false)) / 2

        #expect(travel > 0)
        #expect(travel <= 50)
    }

    // MARK: - The column beside the queue

    @Test("With the queue up, the cover column still clears the band on its own")
    func twoColumnCoverColumnFits() {
        let column = NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + chrome

        #expect(column <= NowPlayingMetrics.tvSafeBandHeight)
    }
}
