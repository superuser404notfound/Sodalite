import SwiftUI

/// The two-column geometry of the wide (tvOS / iPad) Now Playing screen, kept out of the screen
/// itself so it can be hosted and measured in a test without a playback coordinator.
///
/// One rule: the cover column is centred in the band, and the queue column's content starts at the
/// cover's top edge. Sodalite#108 asked for the title block and the first queue row to sit level
/// with the top of the artwork; the first fix (`HStack(alignment: .top)`) read that as a licence to
/// raise the ARTWORK to the queue instead, which pinned it to the top of the title-safe band and,
/// since #110 lets the queue come and go at runtime, moved it up to 97pt on every reveal.
///
/// The inset is measured, not added up, so it follows cover size, text metrics and platform. A
/// custom `VerticalAlignment` looks like the one-pass answer and is not: it slides the queue column
/// down without shortening it, and the list then runs 175pt past the bottom of the screen. Padding
/// inside the column keeps the column the height of the band and spends the inset on its viewport.
struct NowPlayingWideLayout<Cover: View, Queue: View>: View {
    let spacing: CGFloat
    let showsQueue: Bool
    @ViewBuilder let cover: () -> Cover
    @ViewBuilder let queue: () -> Queue

    @State private var coverTop: CGFloat = 0

    private let band = "nowPlayingBand"

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            cover()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(band)).minY
                } action: { top in
                    coverTop = top
                }
                // Greedy in both states, so the cover's own centring never depends on whether the
                // queue is beside it. That independence is the whole point: it is what stops the
                // artwork from travelling when the queue and the chrome leave.
                .frame(maxHeight: .infinity, alignment: .center)

            if showsQueue {
                queue()
                    .padding(.top, coverTop)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .coordinateSpace(.named(band))
    }
}
