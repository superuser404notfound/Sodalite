import Testing
import UIKit
import SwiftUI
@testable import Sodalite

/// Sodalite#108: on the wide (tvOS / iPad) Now Playing screen the album art and the track list did
/// not start level.
///
/// The first fix top-aligned the `HStack`, which levelled them by raising the ARTWORK to the top of
/// the title-safe band. That is the wrong half to move. The queue column holds a `ScrollView` and is
/// therefore always the full height of the band, so a top alignment pins the cover against the
/// SCREEN, not against the queue; once #110 made the queue come and go at runtime the artwork
/// travelled up to 97pt on every reveal, and it sat in the overscan margin in between.
///
/// So what is pinned here is the direction: the cover is centred and the queue's content comes down
/// to it. These run against the real `NowPlayingWideLayout`, hosted at a known size, because the
/// previous version of this file grepped the source for `HStack(alignment: .top` and could not have
/// caught any of it.
@MainActor
struct NowPlayingColumnAlignmentTests {

    private static let band = CGSize(width: 1920, height: 960)

    private final class Frames {
        var cover: CGRect = .zero
        var queueTop: CGRect = .zero
        var queueColumn: CGRect = .zero
    }

    /// A cover column of a known height beside a greedy queue column, the shape the real screen has.
    private struct Harness: View {
        let coverHeight: CGFloat
        let showsQueue: Bool
        let frames: Frames

        var body: some View {
            NowPlayingWideLayout(spacing: 80, showsQueue: showsQueue) {
                Color.clear
                    .frame(width: 560, height: coverHeight)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.cover = $0 }
            } queue: {
                VStack(alignment: .leading, spacing: 28) {
                    Color.clear
                        .frame(height: 187)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.queueTop = $0 }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(0..<12, id: \.self) { _ in Color.clear.frame(height: 65) }
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.queueColumn = $0 }
            }
            // The screen itself lays out behind the tvOS safe area and re-adds the margin as padding
            // (`FullBleedSafeArea`), so the band here is the whole window, not the window minus the
            // inset a bare tvOS UIWindow still carries.
            .ignoresSafeArea()
        }
    }

    private func layout(coverHeight: CGFloat, showsQueue: Bool) -> Frames {
        let frames = Frames()
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.band))
        let controller = UIHostingController(
            rootView: Harness(coverHeight: coverHeight, showsQueue: showsQueue, frames: frames)
        )
        controller.view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.view.layoutIfNeeded()
        return frames
    }

    @Test("The queue's first row starts level with the top of the artwork, not above it")
    func queueStartsLevelWithTheCover() {
        let frames = layout(coverHeight: 600, showsQueue: true)

        #expect(frames.cover.minY == (Self.band.height - 600) / 2)
        #expect(abs(frames.queueTop.minY - frames.cover.minY) <= 1)
    }

    /// The alternative implementation, a custom `VerticalAlignment` on both columns, passes the test
    /// above and fails this one: it slides the full-height queue column down instead of shortening
    /// it, and the list then runs 175pt past the bottom of the screen.
    @Test("Coming down to the cover shortens the queue column, it does not push it off the screen")
    func queueColumnStaysInsideTheBand() {
        let frames = layout(coverHeight: 600, showsQueue: true)

        #expect(frames.queueColumn.maxY <= Self.band.height + 1)
    }

    /// The #110 invariant. The artwork still moves a little between the two states, but only because
    /// the title block moves into its column, never because the queue beside it came or went.
    @Test("The artwork does not move when the queue leaves")
    func coverHoldsStillWhenTheQueueLeaves() {
        let withQueue = layout(coverHeight: 600, showsQueue: true)
        let alone = layout(coverHeight: 600, showsQueue: false)

        #expect(abs(withQueue.cover.minY - alone.cover.minY) <= 1)
    }
}
