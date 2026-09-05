import SwiftUI

/// Manages knownServers: switch (stableTap) + remove (contextMenu); add routes through ServerDiscoveryView.
struct ServerManagementView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?
    @State private var defaultID: String?
    @State private var showAddServerFlow = false
    @State private var pendingRemoval: JellyfinServer?
    /// Non-nil while the switch-failed alert is up: the reason, already run through ErrorText.
    @State private var switchFailure: String?
    #if os(iOS)
    @State private var editingURLsFor: JellyfinServer?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("multiServer.settings.title", bundle: .main)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                ForEach(servers) { server in
                    let remembered = dependencies.listRememberedUsers(serverID: server.id)
                    ServerManagementRow(
                        server: server,
                        isActive: server.id == activeID,
                        isDefault: server.id == defaultID,
                        userCount: remembered.count,
                        rememberedUsers: remembered,
                        onSwitch: { switchTo(server) },
                        onRemove: { pendingRemoval = server },
                        onToggleDefault: { toggleDefault(server) },
                        onEditURLs: {
                            #if os(iOS)
                            editingURLsFor = server
                            #endif
                        }
                    )
                }

                Text("multiServer.settings.longPressHint", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                AddServerSettingsRow(onTap: { showAddServerFlow = true })
                    .padding(.top, 16)
            }
            .screenContentInset()
        }
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $showAddServerFlow) {
            ServerDiscoveryView(addMode: true, onCompletion: {
                showAddServerFlow = false
                load()
            })
            .themedPresentationBackground()
        }
        #if os(iOS)
        .sheet(item: $editingURLsFor) { server in
            DualURLEditSheet(
                title: "multiServer.urls.title",
                internalPlaceholder: "multiServer.urls.internal.placeholder",
                externalPlaceholder: "multiServer.urls.external.placeholder",
                initialInternalURL: server.internalURL,
                initialExternalURL: server.externalURL,
                resolve: ServerAddressResolution.jellyfin(dependencies.serverDiscoveryService),
                onSave: { internalURL, externalURL in
                    try? dependencies.updateServerURLs(
                        serverID: server.id,
                        internalURL: internalURL,
                        externalURL: externalURL
                    )
                    load()
                }
            )
        }
        #endif
        .alert(
            Text("multiServer.remove.confirm.title", bundle: .main),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { server in
            Button("multiServer.remove.confirm.action", role: .destructive) {
                remove(server)
            }
            Button("common.cancel", role: .cancel) {}
        } message: { server in
            Text("multiServer.remove.confirm.message \(server.name)", bundle: .main)
        }
        // The reason, not a fixed line: ServerSwitchError already distinguishes "no longer saved on
        // this device" from "no sign-in saved", and discarding that left the one screen that could
        // explain a failed switch saying nothing (Sodalite#76).
        .alert(
            Text("multiServer.switch.failed.title", bundle: .main),
            isPresented: Binding(
                get: { switchFailure != nil },
                set: { if !$0 { switchFailure = nil } }
            ),
            presenting: switchFailure
        ) { _ in
            Button("common.ok", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidApplyChanges)) { _ in
            load()
        }
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
        defaultID = dependencies.authPreferences.defaultServerID
    }

    private func switchTo(_ server: JellyfinServer) {
        guard server.id != activeID else { return }
        do {
            try dependencies.switchServer(to: server.id)
        } catch DependencyContainer.ServerSwitchError.missingToken {
            // Normal for a server restored from iCloud, whose tokens ride the remembered profiles while
            // the session slot stays device-local: raise that server's profile picker instead of a
            // dead-end alert. Nothing was written, so the current session stands (Sodalite#74).
            appState.pendingProfilePickerServerID = server.id
        } catch {
            dependencies.sessionNote("switch to \(server.name) failed: \(error)")
            switchFailure = ErrorText.user(for: error)
        }
        load()
    }

    private func toggleDefault(_ server: JellyfinServer) {
        // Through the container: the pin rides the server records, so both the newly pinned server
        // and the one that lost the pin have to be republished (Sodalite#45).
        let isDefault = dependencies.authPreferences.defaultServerID == server.id
        dependencies.setDefaultServer(isDefault ? nil : server.id)
        load()
    }

    private func remove(_ server: JellyfinServer) {
        try? dependencies.removeServer(id: server.id)
        load()
    }
}

private struct ServerManagementRow: View {
    let server: JellyfinServer
    let isActive: Bool
    let isDefault: Bool
    let userCount: Int
    let rememberedUsers: [RememberedUser]
    let onSwitch: () -> Void
    let onRemove: () -> Void
    let onToggleDefault: () -> Void
    let onEditURLs: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                #if os(iOS)
                // Phone width cannot fit name + pills + avatars + edit button in one line
                // (the fixedSize pills forced the row past the screen edges); the name gets
                // its own line and the pills a scroll-safe chip row.
                Text(server.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isActive || isDefault {
                    FlowLayout(alignment: .leading, spacing: 8) { badges }
                }
                #else
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    badges
                }
                #endif
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("multiServer.row.userCount \(userCount)", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if !rememberedUsers.isEmpty {
                HStack(spacing: -10) {
                    ForEach(rememberedUsers.prefix(3)) { user in
                        avatarCircle(for: user)
                    }
                    if rememberedUsers.count > 3 {
                        ZStack {
                            Circle()
                                .fill(.regularMaterial)
                                .frame(width: 40, height: 40)
                            Text("+\(rememberedUsers.count - 3)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            #if os(iOS)
            Button {
                onEditURLs()
            } label: {
                Image(systemName: "pencil")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .padding(10)
                    .background(.tint.opacity(0.12), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("multiServer.urls.edit", bundle: .main))
            #endif
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        // The hold belongs to the menu below: without this the row switched servers on the way into
        // its own context menu, which is why an inactive row never showed one (Sodalite#75).
        .stableTap(isFocused: focused, longPressOpensMenu: true) {
            if !isActive { onSwitch() }
        }
        .contextMenu {
            Button {
                onToggleDefault()
            } label: {
                Label {
                    Text(isDefault
                         ? "multiServer.row.action.unsetDefault"
                         : "multiServer.row.action.setDefault",
                         bundle: .main)
                } icon: {
                    Image(systemName: isDefault ? "star.slash" : "star")
                }
            }
            if !isActive {
                Button {
                    onSwitch()
                } label: {
                    Label {
                        Text("multiServer.row.action.switch", bundle: .main)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                }
            }
            #if os(iOS)
            Button {
                onEditURLs()
            } label: {
                Label {
                    Text("multiServer.urls.edit", bundle: .main)
                } icon: {
                    Image(systemName: "link.badge.plus")
                }
            }
            #endif
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label {
                    Text("multiServer.row.action.remove", bundle: .main)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        if isActive {
            StatusPill("multiServer.row.active")
        }
        if isDefault {
            StatusPill("multiServer.row.default")
        }
        #if os(iOS)
        if isActive, let route = dependencies.activeJellyfinRoute {
            StatusPill(route == .internal ? "multiServer.route.internal" : "multiServer.route.external",
                       tone: .neutral)
        }
        #endif
    }

    @ViewBuilder
    private func avatarCircle(for user: RememberedUser) -> some View {
        // Against THIS row's server, not the active one: the list draws every known server's
        // profiles, and the shared image service answers for whichever is active (Sodalite#119).
        let url = dependencies.jellyfinImageService.userProfileImageURL(
            userID: user.id,
            tag: user.imageTag,
            baseURL: dependencies.preferredURL(for: server),
            token: user.token
        )
        ZStack {
            if let url {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsFallback(for: user)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                initialsFallback(for: user)
            }
        }
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 2)
        )
    }

    private func initialsFallback(for user: RememberedUser) -> some View {
        let initials: String = {
            let parts = user.name.split(separator: " ")
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return String(user.name.prefix(2)).uppercased()
        }()
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 40, height: 40)
            Text(initials)
                .font(.caption.bold())
                .foregroundStyle(.primary)
        }
    }
}

private struct AddServerSettingsRow: View {
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("multiServer.settings.add", bundle: .main)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
