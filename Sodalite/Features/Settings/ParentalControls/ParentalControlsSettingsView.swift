import SwiftUI

/// PIN-gated entry whenever a PIN is set (see SettingsView) so nobody handed the remote can disable the lock from here.
struct ParentalControlsSettingsView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    @State private var pinIsSet = false
    @State private var roles: [String: ProfileLockRole] = [:]   // compositeID -> role
    @State private var profiles: [(server: JellyfinServer, user: RememberedUser)] = []
    @State private var setupTarget: PINTarget?
    /// compositeID of every profile that carries an own PIN, read back on every reload so the rows
    /// and the keychain cannot drift apart.
    @State private var ownPINs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Text("parental.title").font(.largeTitle).fontWeight(.bold)
                    .frame(maxWidth: .infinity)

                pinSection
                if pinIsSet { profilesSection }
            }
            .screenContentInset()
        }
        .onAppear(perform: reload)
        .fullScreenCoverCompat(item: $setupTarget) { target in
            PINEntryView(mode: .setup(target)) { _ in
                setupTarget = nil
                reload()
            }
            .pausesAppBackgroundMotion()
        }
    }

    private var pinSection: some View {
        VStack(spacing: 4) {
            ValuePickerRow(
                icon: "lock.shield",
                title: "parental.pin.enable.title",
                subtitle: "parental.pin.enable.subtitle",
                options: [false, true],
                selection: Binding(
                    get: { pinIsSet },
                    set: { newValue in handleEnableChange(newValue) }
                ),
                label: { $0 ? String(localized: "common.on") : String(localized: "common.off") }
            )

            if pinIsSet {
                Button { setupTarget = .guardian } label: {
                    HStack(spacing: 28) {
                        Image(systemName: "key").font(.title2).frame(width: 56).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("parental.pin.change.title").font(.body).fontWeight(.medium)
                            Text("parental.pin.change.subtitle").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(20)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
        }
    }

    private func handleEnableChange(_ enabled: Bool) {
        if enabled {
            setupTarget = .guardian // setup completion flips pinIsSet via reload()
        } else {
            try? dependencies.clearGuardianPIN()
            // Both sets, else hasAnyLockedProfile stays true and the next PIN the user sets
            // silently re-arms locks they believed they had cleared.
            dependencies.parentalControlsPreferences.protectedProfileIDs = []
            dependencies.parentalControlsPreferences.entryLockedProfileIDs = []
            reload()
        }
    }

    private var profilesSection: some View {
        VStack(spacing: 4) {
            Text("parental.profiles.header")
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
            Text("parental.profiles.subtitle")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(profiles, id: \.user.id) { entry in
                let key = ParentalControlsPreferences.compositeID(serverID: entry.server.id, userID: entry.user.id)
                ValuePickerRow(
                    icon: "person.crop.circle",
                    title: LocalizedStringKey(entry.user.name),
                    subtitle: "parental.profile.protect.subtitle",
                    options: ProfileLockRole.allCases,
                    selection: Binding(
                        get: { roles[key] ?? .open },
                        set: { newValue in
                            roles[key] = newValue
                            dependencies.setLockRole(
                                newValue,
                                for: ProfileRef(serverID: entry.server.id, userID: entry.user.id)
                            )
                            reload()
                        }
                    ),
                    label: { role in
                        switch role {
                        case .open:       String(localized: "parental.profile.role.open")
                        case .pinToEnter: String(localized: "parental.profile.role.pinToEnter")
                        case .pinToLeave: String(localized: "parental.profile.role.pinToLeave")
                        }
                    }
                )

                // Only an entry door can carry its own key. A leave lock's PIN would be known to
                // the person being kept in, and an open profile has no door at all.
                if roles[key] == .pinToEnter {
                    let ref = ProfileRef(serverID: entry.server.id, userID: entry.user.id)
                    ValuePickerRow(
                        icon: "key.horizontal",
                        title: "parental.profile.ownPIN.title",
                        subtitle: "parental.profile.ownPIN.subtitle",
                        options: [false, true],
                        selection: Binding(
                            get: { ownPINs.contains(key) },
                            set: { newValue in
                                if newValue {
                                    setupTarget = .profile(ref)
                                } else {
                                    dependencies.clearOwnPIN(for: ref)
                                    reload()
                                }
                            }
                        ),
                        label: { $0 ? String(localized: "common.on") : String(localized: "common.off") }
                    )

                    if ownPINs.contains(key) {
                        Button { setupTarget = .profile(ref) } label: {
                            HStack(spacing: 28) {
                                Image(systemName: "key").font(.title2).frame(width: 56).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("parental.profile.ownPIN.change.title").font(.body).fontWeight(.medium)
                                    Text("parental.profile.ownPIN.change.subtitle").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(20)
                        }
                        .buttonStyle(SettingsTileButtonStyle())
                    }
                }
            }
        }
    }

    private func reload() {
        pinIsSet = dependencies.isGuardianPINSet()
        var list: [(JellyfinServer, RememberedUser)] = []
        for server in dependencies.listKnownServers() {
            for user in dependencies.listRememberedUsers(serverID: server.id) {
                list.append((server, user))
            }
        }
        profiles = list.map { (server: $0.0, user: $0.1) }
        var loaded: [String: ProfileLockRole] = [:]
        for entry in profiles {
            let key = ParentalControlsPreferences.compositeID(serverID: entry.server.id, userID: entry.user.id)
            loaded[key] = dependencies.parentalControlsPreferences.role(
                ProfileRef(serverID: entry.server.id, userID: entry.user.id)
            )
        }
        roles = loaded
        ownPINs = Set(
            profiles
                .map { ProfileRef(serverID: $0.server.id, userID: $0.user.id) }
                .filter { dependencies.hasOwnPIN($0) }
                .map(\.compositeID)
        )
    }
}
