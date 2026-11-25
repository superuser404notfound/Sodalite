import SwiftUI

/// Subtitle overlay for a wired external display (Sodalite#98). Reads the same cue state as the
/// on-frame `SubtitleLayer`, but rendered for a TV: no player chrome, plain-text (no second-window ASS
/// host), transparent background so AVPlayer's external-playback video shows through underneath.
struct ExternalSubtitleView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        ZStack {
            Color.clear
            if !viewModel.overlayCues.isEmpty || !viewModel.shownSecondarySubtitleCues.isEmpty {
                SubtitleOverlayView(
                    cues: viewModel.overlayCues,
                    currentTime: viewModel.subtitleTime,
                    maxCueDuration: viewModel.overlayMaxCueDuration,
                    secondaryCues: viewModel.shownSecondarySubtitleCues,
                    secondaryMaxCueDuration: viewModel.secondarySubtitleMaxCueDuration,
                    fontSize: viewModel.preferences.subtitleFontSize,
                    textColor: viewModel.preferences.subtitleColor,
                    background: viewModel.preferences.subtitleBackground,
                    delaySeconds: viewModel.effectiveSubtitleDelay,
                    verticalPosition: viewModel.preferences.subtitleVerticalPosition,
                    font: viewModel.preferences.subtitleFont,
                    weight: viewModel.preferences.subtitleWeight,
                    controlsVisible: false,
                    assRenderer: nil,
                    assReloadSignal: viewModel.assReloadSignal,
                    activeSubtitleCodec: viewModel.overlaySubtitleCodec,
                    secondarySubtitleCodec: viewModel.activeSecondarySubtitleCodec,
                    hasSecondaryTrack: viewModel.activeSecondarySubtitleIndex != nil,
                    videoSize: viewModel.videoSize,
                    pixelAspect: viewModel.videoPixelAspect
                    // No pictureMode: the external window pins its layer to .resizeAspect
                    // (ExternalSubtitleWindowController), so the picture there is aspect-fit
                    // whatever the device screen is set to, and the overlay's default matches it.
                )
            }
        }
        .ignoresSafeArea()
    }
}
