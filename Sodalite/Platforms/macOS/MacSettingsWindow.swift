import SwiftUI
import AppKit

/// Sodalite > Settings… (Cmd-,): the same Settings screens the other platforms show in a tab, in the
/// window a Mac app keeps them in. The sidebar drops its Settings item on the Mac for the same reason.
///
/// A `Window` behind the standard menu item rather than SwiftUI's `Settings` scene: that one forces
/// the preference-pane toolbar, which centres its items, so a pushed settings page had its back
/// button under the window title, and `windowToolbarStyle` does not reach it.
struct MacSettingsWindowScene<Content: View>: Scene {
    static var windowID: String { "settings" }

    @ViewBuilder let content: () -> Content

    var body: some Scene {
        Window("settings.window.title", id: Self.windowID, content: content)
            .windowResizability(.contentMinSize)
            .restorationBehavior(.disabled)
            .defaultLaunchBehavior(.suppressed)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    SettingsMenuItem()
                }
            }
    }
}

private struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "tab.settings") + "…") {
            openWindow(id: MacSettingsWindowScene<EmptyView>.windowID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

struct MacSettingsWindowContent: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    /// Bumped when a profile switch has to take away what the previous profile unlocked, which
    /// rebuilds the stack at its root. The tab version of this lives in TabRootView; a window of its
    /// own has to watch the switch itself.
    @State private var epoch = 0
    @State private var hostWindow = HostWindowReference()

    var body: some View {
        Group {
            if appState.isAuthenticated {
                SettingsView()
                    .id(epoch)
            } else {
                // Everything in Settings belongs to a signed-in profile, so there is nothing to show
                // until the main window has signed one in.
                Text("auth.login.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 600, idealHeight: 780)
        .background {
            AppBackgroundView(theme: dependencies.appearancePreferences.resolvedTheme(
                isSupporter: dependencies.storeKitService.isSupporter
            ), mode: .automatic)
        }
        .background(HostWindowReader(reference: hostWindow))
        .parentalGateHost(Self.gateHost)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow.window else { return }
            dependencies.parentalGate.pushPresenter(Self.gateHost)
        }
        // The PIN prompt follows the window in front: a challenge raised from the main window while
        // this one is open belongs over the main window. Not while one is up, though: the prompt is
        // a sheet, and a sheet takes key from the window it is attached to.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow.window,
                  dependencies.parentalGate.activeRequest == nil else { return }
            dependencies.parentalGate.popPresenter(Self.gateHost)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow.window else { return }
            dependencies.parentalGate.popPresenter(Self.gateHost)
        }
        .onChange(of: appState.profileKey) { old, new in
            if ProfileShellLayout.switchResetsSettings(
                from: old, to: new,
                escapesGated: dependencies.parentalGateRequiredForSessionAction()
            ) {
                epoch &+= 1
            }
        }
    }

    private static let gateHost = "settings.window"
}
