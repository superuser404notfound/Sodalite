import SwiftUI

struct SettingsView: View {
    /// Non-nil only when presented as the iPhone gear sheet; drives the top-trailing close button.
    /// On iPad/tvOS Settings is a tab/sidebar item, so it stays nil and no close button shows.
    var onClose: (() -> Void)? = nil

    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    @State private var showLogoutConfirm = false
    @State private var showResetConfirm = false
    /// Latches the buttons while the reset runs; deleting the iCloud copy is a round trip.
    @State private var isResetting = false

    var body: some View {
        ThemeNavigationStack {
            ScrollView {
                VStack(spacing: 48) {
                    profileHeader
                    settingsList
                    serverInfo
                    logoutButton
                    resetButton
                    aboutFooter
                }
                .screenContentInset()
            }
            #if os(iOS)
            // The sheet has a swipe-down grabber, but an explicit close matches the gear that
            // opened it (and the detail cover). Pinned outside the ScrollView so it never scrolls;
            // hidden behind any pushed sub-settings screen, which carry their own back button.
            .overlay(alignment: .topTrailing) {
                if let onClose {
                    closeButton(onClose)
                }
            }
            #endif
        }
        // Both session actions ask first. Log Out reads far milder than it is: it does not just end
        // this session, it drops every server, profile and saved login on the device.
        .alert(
            Text("settings.logout.confirm.title", bundle: .main),
            isPresented: $showLogoutConfirm
        ) {
            Button("settings.logout", role: .destructive) {
                performLogout()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.logout.confirm.message", bundle: .main)
        }
        .alert(
            Text("settings.reset.confirm.title", bundle: .main),
            isPresented: $showResetConfirm
        ) {
            Button("settings.reset.confirm.action", role: .destructive) {
                performReset(deleteCloudCopy: false)
            }
            // Only where there is a copy to delete. Without this the reset holds exactly as long as
            // sync stays off: the zone still describes the same servers.
            if dependencies.cloudSync?.isEnabled == true {
                Button("settings.reset.confirm.actionWithCloud", role: .destructive) {
                    performReset(deleteCloudCopy: true)
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.reset.confirm.message", bundle: .main)
        }
        // Settings is the only surface showing server version; refresh on appear so an upgrade since login is picked up.
        .task {
            if let updated = await dependencies.refreshActiveServerVersion() {
                appState.updateActiveServer(updated)
            }
        }
    }

    #if os(iOS)
    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .padding(12)
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.top, 8)
    }
    #endif

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 12) {
            avatar
                .frame(width: 120, height: 120)

            HStack(spacing: 10) {
                // Mirror the badge's width on the leading side so the name stays optically centered
                // while the visible badge sits just to its right, never shifting the name off-center.
                if dependencies.storeKitService.isSupporter {
                    premiumBadge.hidden()
                }

                Text(appState.activeUser?.name ?? "")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                if dependencies.storeKitService.isSupporter {
                    premiumBadge
                }
            }

            Text(appState.activeServer?.name ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var premiumBadge: some View {
        Image("PremiumBadge")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .accessibilityLabel(Text(String(
                localized: "support.pack.unlocked",
                defaultValue: "Unlocked"
            )))
    }

    /// Loads from the server when `primaryImageTag` is set, else initials.
    @ViewBuilder
    private var avatar: some View {
        if let user = appState.activeUser,
           let url = dependencies.jellyfinImageService.userProfileImageURL(
               userID: user.id,
               tag: user.primaryImageTag
           ) {
            AsyncCachedImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                initialsCircle
            }
            .clipShape(Circle())
        } else {
            initialsCircle
        }
    }

    private var initialsCircle: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Text(initials)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private var initials: String {
        let name = appState.activeUser?.name ?? ""
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    // MARK: - Settings List

    private var settingsList: some View {
        // Ordered by reach frequency: Profile, Home, Playback, Appearance (supporter-gated), iCloud Sync, Seerr, Support.
        VStack(spacing: 4) {
            GatedSettingsTile(
                icon: "person.2",
                title: "settings.profile.title",
                subtitle: "settings.profile.subtitle",
                reason: .openParentalSettings,
                requiresPIN: { dependencies.parentalGateRequiredForSessionAction() }
            ) {
                ProfileSettingsView()
            }

            GatedSettingsTile(
                icon: "server.rack",
                title: "multiServer.settings.entry.title",
                subtitle: "multiServer.settings.entry.subtitle",
                reason: .serverManagement,
                requiresPIN: { dependencies.parentalGateRequiredForSessionAction() }
            ) {
                ServerManagementView()
            }

            GatedSettingsTile(
                icon: "lock.shield",
                title: "settings.parental.title",
                subtitle: "settings.parental.subtitle",
                reason: .openParentalSettings,
                // The one screen that can switch the whole thing off asks whatever profile is
                // active: with entry locks, "an unlocked adult profile is on screen" is the normal
                // state, so binding this to the active profile leaves the handover case (an adult
                // unlocks, then passes the remote on) open by default.
                requiresPIN: { dependencies.isGuardianPINSet() }
            ) {
                ParentalControlsSettingsView()
            }

            SettingsTile(
                icon: "square.grid.2x2",
                title: "settings.home.customize",
                subtitle: "settings.home.customizeSubtitle"
            ) {
                HomeCustomizeView()
            }

            // Gated: hiding the Catalog tab is a parental measure (Sodalite#62), so an unlocked
            // profile must not be able to switch it back on.
            GatedSettingsTile(
                icon: "rectangle.3.group",
                title: "settings.tabs.title",
                subtitle: "settings.tabs.subtitle.short",
                reason: .openParentalSettings,
                requiresPIN: { dependencies.parentalGateRequiredForSessionAction() }
            ) {
                TabVisibilitySettingsView()
            }

            SettingsTile(
                icon: "play.circle",
                title: "settings.playback.title",
                subtitle: "settings.playback.subtitle"
            ) {
                PlaybackSettingsView()
            }

            SettingsTile(
                icon: "paintpalette",
                title: "settings.appearance.title",
                subtitle: "settings.appearance.subtitle.short"
            ) {
                AppearanceSettingsView()
            }

            GatedSettingsTile(
                icon: "icloud",
                title: "settings.cloudSync.title",
                subtitle: "settings.cloudSync.subtitle",
                reason: .serverManagement,
                requiresPIN: { dependencies.parentalGateRequiredForSessionAction() }
            ) {
                CloudSyncSettingsView()
            }

            GatedSettingsTile(
                icon: "tray.and.arrow.down",
                title: "settings.seerr.title",
                subtitle: seerrSubtitle,
                reason: .openParentalSettings,
                requiresPIN: { dependencies.parentalGateRequiredForSessionAction() }
            ) {
                SeerrSettingsView()
            }

            // Gated: Support hosts the IAP purchase flow, off-limits to a kid on a protected profile.
            GatedSettingsTile(
                icon: "heart",
                title: "settings.support.title",
                subtitle: "settings.support.subtitle",
                reason: .openParentalSettings,
                requiresPIN: { dependencies.parentalGateRequiredForSessionAction() }
            ) {
                SupportDevelopmentView()
            }

            SettingsTile(
                icon: "chart.bar.xaxis",
                title: "settings.stats.title",
                subtitle: "settings.stats.subtitle"
            ) {
                WatchStatsView()
            }

            SettingsTile(
                icon: "sparkles",
                title: "settings.changelog.title",
                subtitle: "settings.changelog.subtitle"
            ) {
                ChangelogListView()
            }

            SettingsTile(
                icon: "doc.text",
                title: "settings.licenses.title",
                subtitle: "settings.licenses.subtitle"
            ) {
                LicensesView()
            }

            SettingsTile(
                icon: "text.alignleft",
                title: "settings.log.title",
                subtitle: "settings.log.subtitle"
            ) {
                DiagnosticLogView()
            }
        }
    }

    private var seerrSubtitle: LocalizedStringKey {
        appState.isSeerrConnected ? "settings.seerr.subtitle.connected" : "settings.seerr.subtitle.notConnected"
    }

    // MARK: - Server Info

    private var serverInfo: some View {
        // Each column takes an equal share of the width, so the middle item's centre sits on the
        // screen centre regardless of the columns' differing text widths.
        HStack(alignment: .top, spacing: 16) {
            infoItem(label: "settings.about.version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")

            if let server = appState.activeServer, let version = server.version {
                infoItem(label: "settings.about.serverVersion", value: version)
            }

            if let server = appState.activeServer {
                infoItem(label: "settings.about.serverAddress", value: server.url.host ?? "")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func infoItem(label: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - About

    /// Brand footer with app version + credit, below the logout button.
    private var aboutFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return VStack(spacing: 12) {
            footerLogo
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            Text("Sodalite \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            // TMDB attribution, required by their API terms wherever their data/imagery is displayed.
            Text("settings.about.tmdbAttribution")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    @ViewBuilder
    private var footerLogo: some View {
        if dependencies.storeKitService.isSupporter {
            Image("PremiumLogo_Small")
                .resizable()
                .opacity(0.85)
        } else {
            Image("Logo")
                .resizable()
                .opacity(0.85)
        }
    }

    // MARK: - Logout

    private var logoutButton: some View {
        // No destructive role: tvOS renders hard-to-read dark red; SettingsTileButtonStyle sidesteps the tint trap.
        Button {
            showLogoutConfirm = true
        } label: {
            Label("settings.logout", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.body)
                .fontWeight(.medium)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .disabled(isResetting)
        .padding(.top, 12)
    }

    private func performLogout() {
        guard dependencies.parentalGateRequiredForSessionAction() else {
            finishLogout()
            return
        }
        Task {
            await Self.letTheAlertGo()
            if await dependencies.parentalGate.challenge(reason: .logout) {
                finishLogout()
            }
        }
    }

    /// A modal cannot go up while the one before it is still animating away: UIKit refuses and the
    /// cover is dropped without a word. These actions run from an alert button, so the alert is
    /// still on its way out when the PIN prompt asks for the screen. Same wait the deep-link
    /// handover in AppRouter takes.
    private static func letTheAlertGo() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func finishLogout() {
        try? dependencies.clearSession()
        appState.logout()
    }

    // MARK: - Reset

    /// Log Out stops at credentials and servers on purpose. This is the one that also takes the
    /// preferences, for a device that should look like a first launch again (Sodalite#76).
    private var resetButton: some View {
        Button {
            showResetConfirm = true
        } label: {
            Label("settings.reset.button", systemImage: "arrow.counterclockwise")
                .font(.body)
                .fontWeight(.medium)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .disabled(isResetting)
    }

    /// Confirmation first, PIN second, for both session actions: a tap answers immediately, and the
    /// prompt names what is about to go before anything asks the user to prove they may do it.
    private func performReset(deleteCloudCopy: Bool) {
        isResetting = true
        Task {
            // A reset takes the Guardian PIN with it, so a device that has one proves it here.
            // Stricter than the session actions, which only ask while a protected profile is
            // active: by then the lock itself is what is being removed.
            if dependencies.isGuardianPINSet() {
                await Self.letTheAlertGo()
                guard await dependencies.parentalGate.challenge(reason: .logout) else {
                    isResetting = false
                    return
                }
            }
            await dependencies.resetToFactoryState(deleteCloudCopy: deleteCloudCopy)
            appState.logout()
            isResetting = false
        }
    }
}

// MARK: - Settings Tile

struct SettingsTile<Destination: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let destination: () -> Destination

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        NavigationLink {
            destination()
                .hidesShellTabBar()
                .themedNavigationDestination()
        } label: {
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
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }
}

/// SettingsTile that presents the Guardian-PIN challenge when `requiresPIN()`, navigating only on success.
struct GatedSettingsTile<Destination: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let reason: PINReason
    let requiresPIN: () -> Bool
    @ViewBuilder let destination: () -> Destination

    @Environment(\.dependencies) private var dependencies
    @State private var navigate = false

    var body: some View {
        Button { gateThenNavigate() } label: {
            HStack(spacing: 28) {
                Image(systemName: icon).font(.title2).frame(width: 56, alignment: .center).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .navigationDestination(isPresented: $navigate) {
            destination()
                .hidesShellTabBar()
                .themedNavigationDestination()
        }
    }

    private func gateThenNavigate() {
        guard requiresPIN() else { navigate = true; return }
        Task {
            if await dependencies.parentalGate.challenge(reason: reason) { navigate = true }
        }
    }
}

struct SettingsTileButtonStyle: ButtonStyle {
    /// The screen's primary action wears the accent fill instead of the resting white 0.05 tile.
    /// On an OLED-black backdrop that tile is nearly invisible, so a setup step that ends in one
    /// reads as already finished and the user navigates away mid-flow (Sodalite#82). Fill values
    /// match GlassButtonStyle's prominent variant so a primary action looks the same everywhere.
    var isProminent: Bool = false
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif
    /// A custom ButtonStyle must self-dim when disabled; the default bordered style auto-dims, this one doesn't.
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appearanceTheme) private var appearanceTheme

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        let active = isFocused
        #else
        let active = configuration.isPressed
        #endif
        return configuration.label
            // Same fill as GlassButtonStyle's prominent variant, so the same rule about what goes
            // on top of it applies (Sodalite#111). Only the prominent tile: a resting tile is a dim
            // white on a dark ground, and its label is the call site's to colour.
            .foregroundStyle(isProminent
                ? AnyShapeStyle(appearanceTheme.palette.foreground.color)
                : AnyShapeStyle(.foreground))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(fill(active: active))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(active ? 1 : 0)
            )
            .scaleEffect(active ? 1.03 : 1.0)
            .shadow(color: .black.opacity(active ? 0.3 : 0), radius: 15, y: 8)
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.2), value: active)
    }

    private func fill(active: Bool) -> AnyShapeStyle {
        if isProminent {
            return AnyShapeStyle(TintShapeStyle.tint.opacity(active ? 0.9 : 0.7))
        }
        return AnyShapeStyle(Color.white.opacity(active ? 0.15 : 0.05))
    }
}

/// Pass-through style for cards drawing their own focus ring; suppresses tvOS' thick white halo (any custom ButtonStyle suffices).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Focus stroke+scale+shadow without bg fill, for buttons that paint their own backdrop; .plain would tint the label + draw the white halo.
struct GhostTileButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif
    @Environment(\.isEnabled) private var isEnabled
    /// Matches the rounded shape of the button's own label background.
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        let active = isFocused
        #else
        let active = configuration.isPressed
        #endif
        return configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(active ? 1 : 0)
            )
            .scaleEffect(active ? 1.03 : 1.0)
            .shadow(color: .black.opacity(active ? 0.3 : 0), radius: 15, y: 8)
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.2), value: active)
    }
}
