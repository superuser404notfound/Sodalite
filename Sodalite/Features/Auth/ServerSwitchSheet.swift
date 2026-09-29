import SwiftUI

/// Modal sheet to pick among `knownServers` or add one. Presented from `LaunchProfilePickerView` and `ServerManagementView`.
struct ServerSwitchSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    /// Host is expected to push/fullScreenCover a ServerDiscoveryView in add-mode.
    let onAddServer: () -> Void

    /// Bool indicates whether the switch succeeded; host reacts (dismiss on success, toast on failure).
    let onSwitched: (Bool) -> Void

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?

    var body: some View {
        #if os(iOS)
        // A system sheet on iOS: the page's own theme background and a close button, like every
        // other sheet here. The material card below is the tvOS panel, and inside a sheet it read
        // as a second, darker sheet with no way out but a swipe.
        NavigationStack {
            content(horizontalInset: 20)
                .padding(.top, 8)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .themedNavigationDestination()
        }
        .onAppear(perform: load)
        .themedPresentationBackground()
        #else
        content(horizontalInset: 40)
            .frame(maxWidth: 900, maxHeight: 700)
            .padding(40)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onAppear(perform: load)
            .themedPresentationBackground()
        #endif
    }

    private func content(horizontalInset: CGFloat) -> some View {
        VStack(spacing: 24) {
            Text("multiServer.switchSheet.title", bundle: .main)
                .font(.title2.bold())
                .foregroundStyle(.primary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(servers) { server in
                        ServerRow(
                            server: server,
                            isActive: server.id == activeID,
                            onTap: { switchTo(server) }
                        )
                    }
                    AddServerRow(onTap: {
                        dismiss()
                        onAddServer()
                    })
                }
                .padding(.horizontal, horizontalInset)
            }
        }
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
    }

    private func switchTo(_ server: JellyfinServer) {
        if server.id == activeID {
            dismiss()
            return
        }
        do {
            try dependencies.switchServer(to: server.id)
            onSwitched(true)
        } catch DependencyContainer.ServerSwitchError.missingToken {
            // No session on the target this device may resume unasked (Sodalite#74): hand it to
            // AppRouter, which offers that server's profiles. switchServer threw before it wrote
            // anything, so there is nothing to roll back and the current session stands.
            appState.pendingProfilePickerServerID = server.id
            onSwitched(false)
        } catch {
            onSwitched(false)
        }
        dismiss()
    }
}

private struct ServerRow: View {
    let server: JellyfinServer
    let isActive: Bool
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                StatusPill("multiServer.row.active")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(focused ? Color.Theme.focusFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
        )
        .focusStroke(RoundedRectangle(cornerRadius: 14, style: .continuous), isFocused: focused)
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}

private struct AddServerRow: View {
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("multiServer.row.add", bundle: .main)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(focused ? Color.Theme.focusFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
        )
        .focusStroke(RoundedRectangle(cornerRadius: 14, style: .continuous), isFocused: focused)
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
