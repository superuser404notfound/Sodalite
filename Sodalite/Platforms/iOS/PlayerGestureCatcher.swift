import SwiftUI
import UIKit

/// Full-screen SwiftUI gesture catcher at the bottom of the overlay z-stack (below the controls,
/// above the video): single-tap toggles controls (and closes a dropdown via hideControls),
/// double-tap on the left/right third skips by the interval configured for that direction (middle =
/// play/pause), a vertical drag near the left/right EDGE sets brightness / volume. The wide center is
/// a dead zone, so a minimize / swipe gesture there does not accidentally change brightness or
/// volume. A plain SwiftUI layer (Color.clear) reliably receives empty-area taps in the hosting
/// overlay; the controls render above and win their hits.
struct PlayerGestureCatcher: View {
    let viewModel: PlayerViewModel

    @State private var panAxis: PanAxis = .undecided
    @State private var panZone: PanZone = .none
    @State private var panStartLevel: Double = 0
    private enum PanAxis { case undecided, vertical, horizontalIgnored }
    private enum PanZone { case brightness, volume, none }
    /// Brightness/volume vertical swipes are confined to a strip this fraction wide at each edge; the rest
    /// of the width is a dead center so a minimize / swipe gesture there does not change brightness or volume.
    /// 0.18 keeps the strip ~70pt in iPhone portrait, still comfortably above a 44pt touch target.
    private static let edgeZoneFraction: CGFloat = 0.18

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    if let direction = PlayerTouchInput.skipDirection(forTapX: location.x, width: geo.size.width) {
                        viewModel.skipByConfiguredInterval(direction: direction)
                    } else {
                        viewModel.togglePlayPause()
                    }
                }
                .onTapGesture {
                    if viewModel.showControls { viewModel.hideControls() }
                    else { viewModel.showControlsTemporarily() }
                }
                .simultaneousGesture(verticalPan(in: geo.size))
        }
    }

    private func verticalPan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if panAxis == .undecided {
                    let isVertical = abs(value.translation.height) > abs(value.translation.width)
                    var zone = Self.zone(forStartX: value.startLocation.x, width: size.width)
                    // Sodalite#156: while the picture is on a receiver, dimming this screen only dims
                    // the artwork on it. Volume survives: an AirPlay 2 receiver takes the device's.
                    if zone == .brightness, !ExternalPlaybackPresentation.localPictureControlsApply(
                        destination: viewModel.externalPlaybackDestination) {
                        zone = .none
                    }
                    // A swipe the viewer switched off is a dead strip, like the center (Sodalite#194).
                    if let control = Self.control(for: zone),
                       !viewModel.preferences.playerControls.isVisible(control, in: .gestures) {
                        zone = .none
                    }
                    if isVertical, zone != .none {
                        panAxis = .vertical
                        panZone = zone
                        panStartLevel = zone == .brightness ? Double(Self.brightness) : Double(PlayerSystemVolume.current)
                    } else {
                        // Vertical drag in the dead center, or a horizontal drag: ignore so it can't change levels.
                        panAxis = .horizontalIgnored
                    }
                }
                guard panAxis == .vertical else { return }
                let level = panStartLevel + PlayerTouchInput.levelDelta(translationY: value.translation.height, height: size.height)
                if panZone == .brightness { viewModel.setBrightness(CGFloat(level)) }
                else if panZone == .volume { viewModel.setVolume(Float(level)) }
            }
            .onEnded { _ in panAxis = .undecided; panZone = .none }
    }

    private static func control(for zone: PanZone) -> PlayerControl? {
        switch zone {
        case .brightness: .brightnessSwipe
        case .volume: .volumeSwipe
        case .none: nil
        }
    }

    /// Classify a drag's start X into the left brightness strip, the right volume strip, or the dead center.
    private static func zone(forStartX x: CGFloat, width: CGFloat) -> PanZone {
        guard width > 0 else { return .none }
        let edge = width * edgeZoneFraction
        if x < edge { return .brightness }
        if x > width - edge { return .volume }
        return .none
    }

    private static var brightness: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen.brightness ?? 0.5
    }
}
