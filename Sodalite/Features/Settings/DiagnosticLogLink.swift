import SwiftUI

/// The diagnostic log, reached from a screen that has no Settings behind it.
///
/// Setup is where the log matters most and where it was the one place unreachable from. Before a
/// server is added there is no tab bar and no Settings at all, so the person who has to read the
/// lines, the one whose server will not connect, was the only one who could not get to them. The
/// same screen in add-mode is a full-screen cover over Settings, which is the other half of the
/// same gap (Discord report, 2026-08-30).
///
/// Placed only where a failure is already on screen. A log button next to a scan that is working
/// is noise, and the lines mean nothing to somebody who has no question yet.
struct DiagnosticLogLink: View {
    /// `.inline` is a quiet text link for the touch sign-in screens, where a tile beside the
    /// screen's real actions reads as one of them.
    enum Style { case tile, inline }
    var style: Style = .tile

    @State private var isPresented = false

    var body: some View {
        button
            .menuPresentation(isPresented: $isPresented, panel: .plain) {
                // The log dismisses itself: Menu on tvOS through its own onExitCommandCompat, the
                // gesture on iOS.
                DiagnosticLogView()
                    .themedPresentationBackground()
            }
    }

    @ViewBuilder
    private var button: some View {
        switch style {
        case .tile:
            Button {
                isPresented = true
            } label: {
                Text("settings.log.title")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(SettingsTileButtonStyle())
        case .inline:
            Button {
                isPresented = true
            } label: {
                Label("settings.log.title", systemImage: "doc.text.magnifyingglass")
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 6)
            }
            #if os(tvOS)
            .buttonStyle(TVOnboardingLinkStyle())
            #else
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            #endif
        }
    }
}
