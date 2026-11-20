#if !os(macOS)
// Player chrome for the UIKit host: it is display-only by construction, because
// PlayerHostController owns every press and moves a cursor through it. macOS has its own
// transport, whose controls handle their own clicks (Platforms/macOS/MacPlayerScreen.swift).
import SwiftUI

/// Sodalite#104: one sentence the player shows for a few seconds and then forgets.
///
/// Deliberately not the error surface. Nothing failed when a pause outlives the live buffer: the
/// session simply cannot resume where it stopped, because the sliding window took that stretch while
/// the viewer was away. An error would overstate it and a silent jump understates it, which is what
/// shipped until now.
///
/// Both transports mount it in the same place, just above the controls, because that is where a
/// viewer is already looking at the moment it appears: they have just pressed play.
struct PlayerNoticeBanner: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.Theme.scrimHeavy))
                .overlay(Capsule().strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 12)
        }
    }
}
#endif
