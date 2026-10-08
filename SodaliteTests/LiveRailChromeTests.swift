import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// Sodalite#104 round 2: the two findings from the device round that are about the rail's chrome
/// rather than its geometry, pinned as numbers.
///
/// Both were one mistake made twice: a size measured for the phone and then drawn on the television.
/// The row was 30 pt tall on both platforms, which covers the phone's `.caption` line and falls 7 pt
/// short of tvOS `.callout`, and the press readout was a two-line column of 66 pt centred on that
/// row, so it spent 18 pt upwards, into the 4 pt that separated the row from a scrub knob which is
/// 22 pt wide at exactly the moment the readout exists.
@Suite("The live rail's chrome (Sodalite#104 round 2)")
struct LiveRailChromeTests {

    private func size(_ view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    }

    // MARK: - A row is as tall as the line it draws

    @Test func theRowCoversItsOwnTextLine() {
        #if os(tvOS)
        let line = UIFont.preferredFont(forTextStyle: .callout).lineHeight
        #else
        let line = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        #endif
        #expect(LiveRailLabels.defaultRowHeight >= line)
    }

    /// The row asks the system how tall its glyphs are, and this is the assumption that lets it ask
    /// without rendering anything: a symbol image reports the height SwiftUI lays the same symbol
    /// out at. Measured true for all twenty skip glyphs and both hold chevrons on tvOS 26.5 and
    /// 27.0. The day it stops being true, the row goes back to guessing and this says so.
    @Test func aSymbolImageIsAsTallAsTheSymbolSwiftUIDraws() {
        #if os(tvOS)
        let configuration = UIImage.SymbolConfiguration(textStyle: .callout)
        for name in SeekReadout.drawableGlyphNames {
            let drawn = size(Image(systemName: name).font(.callout)).height
            let measured = UIImage(systemName: name, withConfiguration: configuration)?.size.height
            #expect(measured == drawn, "\(name): image says \(measured as Any), SwiftUI draws \(drawn)")
        }
        #endif
    }

    /// A readout taller than its row spends the difference upwards, where the track is.
    ///
    /// Not a tautology now that the row is derived: it holds the derivation against the readout as
    /// it is actually laid out, spacing and all, rather than against the glyph the derivation asked
    /// about. tvOS 27 grew that glyph from 39.5 to 41.0 pt and the pinned 40 went one point short.
    @Test func aPressReadoutFitsInsideItsRow() {
        let single = size(SeekReadoutView(readout: .press(seconds: 10, count: 1, direction: -1)))
        let burst = size(SeekReadoutView(readout: .press(seconds: 10, count: 4, direction: -1)))
        #expect(single.height <= LiveRailLabels.defaultRowHeight)
        #expect(burst.height <= LiveRailLabels.defaultRowHeight)
        // The burst count belongs beside the glyph, not under it: it may cost width, never height.
        #expect(burst.height == single.height)
        #expect(burst.width > single.width)
    }

    @Test func aHoldReadoutFitsInsideItsRow() {
        #expect(size(SeekReadoutView(readout: .hold(rate: 96, direction: 1))).height
                <= LiveRailLabels.defaultRowHeight)
    }

    // MARK: - The badge says its status in a colour the word can carry

    private func resolved(_ color: Color) -> RGBColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32(min(255, max(0, (value * 255).rounded())))
        }
        return RGBColor(hex: channel(r) << 16 | channel(g) << 8 | channel(b))
    }

    /// `restFillStrong` is white at 0.12, blended in the gamma-encoded space the colours are
    /// authored in, over whatever the picture leaves behind it.
    private func pill(overGround ground: Double) -> RGBColor {
        let level = 0.12 + 0.88 * ground
        let channel = UInt32((min(1, max(0, level)) * 255).rounded())
        return RGBColor(hex: channel << 16 | channel << 8 | channel)
    }

    /// The badge sits low in the control scrim, which is at least 0.7 black there, so the brightest
    /// ground white artwork can push through its pill is 0.3.
    @Test func theBadgeWordIsReadableOnItsOwnPill() {
        let green = resolved(Color.Theme.success)
        for ground in [0.0, 0.3] {
            let ratio = green.contrastRatio(with: pill(overGround: ground))
            #expect(ratio >= 3.0, "the LIVE word reads at \(ratio):1 over ground \(ground)")
        }
    }

    /// Why the colour is on the word and not on the fill, kept as a test so the number that decided
    /// it stays attached to it: the filled pill this replaced cannot carry a white label.
    @Test func aFilledStatusPillCouldNotHaveCarriedItsLabel() {
        let green = resolved(Color.Theme.success)
        #expect(RGBColor.white.contrastRatio(with: green) < 3.0)
    }

    // MARK: - Play over a pending scrub

    /// Play over a swiped-to position means go there and play. It used to toggle the transport, which
    /// paused the session with the target still pending.
    @Test func playCommitsAPendingScrubInsteadOfTogglingTheTransport() {
        #expect(PlayerHostController.playPausePress(isScrubbing: true, isPlaying: true)
                == .commitScrub(thenPlay: false))
        #expect(PlayerHostController.playPausePress(isScrubbing: true, isPlaying: false)
                == .commitScrub(thenPlay: true))
        #expect(PlayerHostController.playPausePress(isScrubbing: false, isPlaying: true) == .toggle)
        #expect(PlayerHostController.playPausePress(isScrubbing: false, isPlaying: false) == .toggle)
    }

    /// Up and Down change the channel on live, so the click is what opens the bar there, and the
    /// second click pauses. VOD keeps the click as play/pause.
    @Test func aLiveClickOpensTheBarBeforeItPauses() {
        #expect(PlayerHostController.hiddenControlsSelect(isLive: true, controlsVisible: false) == .showControls)
        #expect(PlayerHostController.hiddenControlsSelect(isLive: true, controlsVisible: true) == .togglePlayback)
        #expect(PlayerHostController.hiddenControlsSelect(isLive: false, controlsVisible: false) == .togglePlayback)
        #expect(PlayerHostController.hiddenControlsSelect(isLive: false, controlsVisible: true) == .togglePlayback)
    }
}
