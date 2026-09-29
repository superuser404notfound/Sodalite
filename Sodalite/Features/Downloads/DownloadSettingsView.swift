#if os(iOS)
import SwiftUI

/// Settings > Downloads (Sodalite#81): Wi-Fi only, storage used, delete this profile's downloads.
struct DownloadSettingsView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var confirmsDeleteAll = false
    /// Measured once per change, not per body pass (a directory walk).
    @State private var usage = DownloadStore.Usage(items: 0, bytes: 0)

    /// The ACTIVE profile only, like the Downloads tab: on a shared iPad one profile must not delete
    /// another's downloads from here.
    private var scope: DownloadCleanupScope? {
        dependencies.downloadStore.activeProfile.map { .profile(serverID: $0.serverID, userID: $0.userID) }
    }

    var body: some View {
        let prefs = dependencies.downloadPreferences
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.downloads.title")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)

                ValuePickerRow(
                    icon: "wifi",
                    title: "settings.downloads.wifiOnly",
                    subtitle: "settings.downloads.wifiOnly.subtitle",
                    options: [false, true],
                    selection: Binding(get: { prefs.wifiOnly }, set: { prefs.wifiOnly = $0 }),
                    label: { on in
                        on ? String(localized: "settings.playback.on", defaultValue: "On")
                           : String(localized: "settings.playback.off", defaultValue: "Off")
                    }
                )
                .settingsValueScope(.device)

                HStack {
                    Label("settings.downloads.storage", systemImage: "internaldrive")
                    Spacer()
                    Text(usage.bytes.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                }
                .padding()

                Button(role: .destructive) { confirmsDeleteAll = true } label: {
                    Text("downloads.deleteAll").padding(.horizontal, 32).padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle(isProminent: false))
                .frame(maxWidth: .infinity)
                .disabled(usage.items == 0)
            }
            .padding()
        }
        // A running task keeps the network access it started with, so a change restarts them.
        .onChange(of: prefs.wifiOnly) { _, _ in
            Task { await dependencies.downloadManager?.applyNetworkPolicy() }
        }
        .task(id: dependencies.downloadStore.items.count) { measure() }
        .alert("downloads.deleteAll.confirm.title", isPresented: $confirmsDeleteAll) {
            Button("downloads.deleteAll", role: .destructive) {
                guard let scope else { return }
                Task {
                    await DownloadCleanup.perform(scope, store: dependencies.downloadStore,
                                                  manager: dependencies.downloadManager)
                    measure()
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("downloads.deleteAll.confirm.body \(usage.items) \(usage.bytes.formatted(.byteCount(style: .file)))")
        }
    }

    private func measure() {
        guard let scope else { usage = .init(items: 0, bytes: 0); return }
        usage = DownloadCleanup.usage(scope, store: dependencies.downloadStore)
    }
}
#endif
