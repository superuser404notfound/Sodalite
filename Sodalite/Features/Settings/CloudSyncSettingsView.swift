import SwiftUI

/// iCloud sync controls: enable toggle, status, manual settings push, and
/// cloud-data deletion. Rows follow the Settings conventions (ValuePickerRow
/// for on/off, SettingsTileButtonStyle buttons, .alert confirms).
struct CloudSyncSettingsView: View {
    @Environment(\.dependencies) private var dependencies

    @State private var isPulling = false
    @State private var confirmPush = false
    @State private var confirmDelete = false

    /// Read from the service, not copied on appear: sync can switch itself off while this screen is up
    /// (another device deleted the iCloud data, an account change), and a copy kept showing "On" over
    /// a service that was off, so turning it back on meant leaving the screen first.
    private var isEnabled: Bool { dependencies.cloudSync?.isEnabled ?? true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                header

                sectionHeader("settings.cloudSync.section.general")

                ValuePickerRow(
                    icon: "icloud",
                    title: "settings.cloudSync.enabled.title",
                    subtitle: "settings.cloudSync.enabled.subtitle",
                    options: [false, true],
                    selection: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            dependencies.cloudSync?.setEnabled(newValue)
                        }
                    ),
                    label: { on in
                        on
                            ? String(localized: "settings.playback.on", defaultValue: "On")
                            : String(localized: "settings.playback.off", defaultValue: "Off")
                    }
                )

                statusRow

                sectionHeader("settings.cloudSync.section.actions")

                actionRow(
                    icon: "arrow.up.to.line",
                    title: "settings.cloudSync.push.title",
                    subtitle: "settings.cloudSync.push.subtitle",
                    disabled: !isEnabled
                ) { confirmPush = true }

                actionRow(
                    icon: "arrow.down.to.line",
                    title: "settings.cloudSync.pull.title",
                    subtitle: "settings.cloudSync.pull.subtitle",
                    disabled: !isEnabled || isPulling
                ) {
                    isPulling = true
                    Task {
                        await dependencies.cloudSync?.pullSettingsFromCloud()
                        isPulling = false
                    }
                }

                actionRow(
                    icon: "trash",
                    title: "settings.cloudSync.delete.title",
                    subtitle: "settings.cloudSync.delete.subtitle",
                    disabled: false
                ) { confirmDelete = true }
            }
            .screenContentInset()
        }
        .hidesNavigationBarChrome()
        .alert(
            Text("settings.cloudSync.push.confirm.title", bundle: .main),
            isPresented: $confirmPush
        ) {
            Button("settings.cloudSync.push.confirm.action") {
                dependencies.cloudSync?.pushLocalSettingsToAllDevices()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.cloudSync.push.confirm.message", bundle: .main)
        }
        .alert(
            Text("settings.cloudSync.delete.confirm.title", bundle: .main),
            isPresented: $confirmDelete
        ) {
            Button("settings.cloudSync.delete.confirm.action", role: .destructive) {
                Task {
                    await dependencies.cloudSync?.deleteCloudDataAndDisable()
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.cloudSync.delete.confirm.message", bundle: .main)
        }
    }

    private var header: some View {
        Text("settings.cloudSync.title", bundle: .main)
            .font(.largeTitle)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 28) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .frame(width: 56, alignment: .center)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.cloudSync.status.title", bundle: .main)
                    .font(.body)
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch dependencies.cloudSync?.status {
        case .active: "checkmark.icloud"
        case .syncing: "icloud.and.arrow.up"
        case .noAccount: "xmark.icloud"
        case .accountChanged: "person.icloud"
        case .error: "exclamationmark.icloud"
        case .disabled, nil: "icloud.slash"
        }
    }

    private var statusText: String {
        switch dependencies.cloudSync?.status {
        case .active(let lastSyncAt):
            if let lastSyncAt {
                let formatted = lastSyncAt.formatted(date: .abbreviated, time: .shortened)
                return String(format: String(localized: "settings.cloudSync.status.lastSync %@", defaultValue: "Active, last synced %@"), formatted)
            }
            return String(localized: "settings.cloudSync.status.active", defaultValue: "Active")
        case .syncing:
            return String(localized: "settings.cloudSync.status.syncing", defaultValue: "Syncing…")
        case .noAccount:
            return String(localized: "settings.cloudSync.status.noAccount", defaultValue: "No iCloud account")
        case .accountChanged:
            return String(localized: "settings.cloudSync.status.accountChanged", defaultValue: "Paused: a different iCloud account signed in. Turn sync back on to use it with this account.")
        case .error(let message):
            // Naming the CloudKit error is the whole point: "Sync error" alone made a stale
            // record identity, an expired change token and a full iCloud look identical.
            return String(
                format: String(localized: "settings.cloudSync.status.error %@", defaultValue: "Sync error: %@"),
                message
            )
        case .disabled, nil:
            return String(localized: "settings.cloudSync.status.disabled", defaultValue: "Off")
        }
    }

    private func actionRow(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 28) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 56, alignment: .center)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 4)
    }
}
