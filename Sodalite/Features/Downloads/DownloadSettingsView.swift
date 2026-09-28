#if os(iOS)
import SwiftUI

/// Settings > Downloads (Sodalite#81): Wi-Fi only, storage used, delete everything.
struct DownloadSettingsView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var confirmsDeleteAll = false

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
                    Text(dependencies.downloadStore.totalUsage().bytes.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                }
                .padding()

                Button(role: .destructive) { confirmsDeleteAll = true } label: {
                    Text("downloads.deleteAll").padding(.horizontal, 32).padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle(isProminent: false))
                .frame(maxWidth: .infinity)
                .disabled(dependencies.downloadStore.totalUsage().items == 0)
            }
            .padding()
        }
        .alert("downloads.deleteAll.confirm.title", isPresented: $confirmsDeleteAll) {
            Button("downloads.deleteAll", role: .destructive) {
                Task {
                    await DownloadCleanup.perform(.everything, store: dependencies.downloadStore,
                                                  manager: dependencies.downloadManager)
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            let usage = dependencies.downloadStore.totalUsage()
            Text("downloads.deleteAll.confirm.body \(usage.items) \(usage.bytes.formatted(.byteCount(style: .file)))")
        }
    }
}
#endif
