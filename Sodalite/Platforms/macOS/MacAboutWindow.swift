import SwiftUI
import AppKit
import AetherEngine

/// Sodalite > About Sodalite. Replaces the standard panel, which can show only a name, a version and
/// a credits blob: this one also carries the engine version a playback report is read against, the
/// TMDB attribution their API terms require wherever their data is shown, and the way to the
/// changelog, the licenses and the community.
struct MacAboutWindowScene: Scene {
    static let windowID = "about"

    var body: some Scene {
        Window("about.title", id: Self.windowID) {
            MacAboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
        }
    }
}

private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("about.title") {
            openWindow(id: MacAboutWindowScene.windowID)
        }
    }
}

private struct MacAboutView: View {
    private enum Sheet: Identifiable {
        case changelog, licenses
        var id: Self { self }
    }

    @State private var sheet: Sheet?

    private static let repository = URL(string: "https://github.com/superuser404notfound/Sodalite")!
    private static let discussions = URL(string: "https://github.com/superuser404notfound/Sodalite/discussions")!
    private static let discord = URL(string: "https://discord.gg/P7NvpzNqnG")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)

            Text(verbatim: "Sodalite")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, 8)

            Text("about.tagline")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            versions
                .padding(.top, 14)

            HStack(spacing: 10) {
                Button("settings.changelog.title") { sheet = .changelog }
                Button("settings.licenses.title") { sheet = .licenses }
            }
            .controlSize(.large)
            .buttonStyle(.glass)
            .padding(.top, 22)

            HStack(spacing: 18) {
                Link(destination: Self.repository) { Text(verbatim: "GitHub") }
                Link(destination: Self.discussions) { Text("about.discussions") }
                Link(destination: Self.discord) { Text(verbatim: "Discord") }
            }
            .font(.callout)
            .padding(.top, 16)

            Divider()
                .padding(.vertical, 18)

            VStack(spacing: 6) {
                Text(verbatim: "© 2026 Vincent Herbst · GPL-3.0")
                // Required by TMDB's API terms wherever their data or imagery is displayed.
                Text("settings.about.tmdbAttribution")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .containerBackground(.thickMaterial, for: .window)
        // Dark like every other window of the app, whatever the system appearance.
        .preferredColorScheme(.dark)
        .windowMinimizeBehavior(.disabled)
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .changelog: ChangelogListView()
                case .licenses: LicensesView()
                }
            }
            .frame(width: 640, height: 720)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { self.sheet = nil }
                }
            }
        }
    }

    /// Both lines are what a bug report gets asked for, so they can be selected and copied as is.
    private var versions: some View {
        VStack(spacing: 2) {
            // verbatim: version numbers are not translatable, and without it the string catalog
            // grows an empty key per format on every build that extracts strings.
            HStack(spacing: 4) {
                Text("settings.about.version")
                Text(verbatim: "\(version) (\(build))")
            }
            .font(.callout)
            Text(verbatim: "AetherEngine \(AetherEngine.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }
}
