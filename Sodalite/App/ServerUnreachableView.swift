import SwiftUI

/// What Home says when the server does not answer from where the device is standing (Sodalite#122).
///
/// It replaces one generic line, "Couldn't reach your server. Check the connection and try again.",
/// which on a phone off Wi-Fi is not merely vague but a wrong lead: the connection is fine, the
/// address is the problem, and the sentence sends the reader to restart a router they are nowhere
/// near. That is the same failure Sodalite#92 was written to remove, one case over.
///
/// Two shapes deliberately. It lives inside the tab content rather than over everything, because
/// the fix for the case that has one is in Settings and a full-screen cover hides the tab bar that
/// leads there. And its actions are a list rather than a hard-coded button, so the offline
/// downloads state (#81) prepends "Go to Downloads" without any of this being rewritten.
///
/// Nothing here ever claims the absence is total. "This server is not reachable from this network"
/// stays true once downloads exist; "nothing to watch" would not, and it is the sentence that would
/// have to be retracted.
struct ServerUnreachableView: View {
    let state: ServerReachability
    let serverName: String
    /// Offered only where there is a slot to fill and a sheet to fill it in.
    let onAddExternalAddress: (() -> Void)?
    let onRetry: () async -> Void

    @State private var isRetrying = false

    private var symbol: String {
        switch state {
        case .noNetwork: "wifi.slash"
        default: "network.slash"
        }
    }

    private var title: Text {
        switch state {
        case .noNetwork:
            Text("server.noNetwork.title")
        case .offNetwork:
            Text("server.offNetwork.title \(serverName)")
        default:
            Text("server.unreachable.title \(serverName)")
        }
    }

    /// Address advice, and exactly where the action is. Those two travel together by construction:
    /// the sentence explains the button, and a button with no explanation, or an explanation with no
    /// button, is the half that reads as a dead end.
    private var subtitle: Text? {
        onAddExternalAddress == nil ? nil : Text("server.offNetwork.body")
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                title
                    .multilineTextAlignment(.center)
                if let subtitle {
                    subtitle
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 620)

            VStack(spacing: 14) {
                if let onAddExternalAddress {
                    Button(action: onAddExternalAddress) {
                        Text("server.offNetwork.addExternal")
                            .font(.body)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsTileButtonStyle(isProminent: true))
                }

                Button {
                    Task {
                        isRetrying = true
                        await onRetry()
                        isRetrying = false
                    }
                } label: {
                    Group {
                        if isRetrying {
                            ProgressView()
                        } else {
                            Text("home.retry").font(.body)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                }
                // Prominent where it stands alone: on this backdrop a resting tile is barely there,
                // and a screen whose only way forward reads as decoration is the Sodalite#82
                // complaint one screen over. Where the add-address button is present that one is the
                // primary and this one must stay under it.
                .buttonStyle(SettingsTileButtonStyle(isProminent: onAddExternalAddress == nil))
                .disabled(isRetrying)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tells the tab's status strip to stay quiet: this screen is already saying it (#126).
        .preference(key: ServerUnreachableScreenKey.self, value: true)
    }
}

extension ServerUnreachableView {
    /// The add-an-external-address action, where there is both a slot to fill and a sheet to fill it
    /// in.
    ///
    /// tvOS has no URL editor at all, so there it stays nil and the screen offers Retry alone: a
    /// button that leads nowhere is worse than no button. The sentence above it is true on both.
    ///
    /// Shared with the library grid for the same reason the verdict itself is: two screens saying
    /// one sentence must not grow two answers to when the fix can be offered with it.
    ///
    /// The EMPTY SLOT decides, not the verdict's name (Sodalite#126). A server whose external slot
    /// is free is the one a remote address fixes; a public server that stopped answering has its
    /// internal slot free instead, and offering to add a LAN address for it is noise. `.unreachable`
    /// carries the offer alongside `.offNetwork` because the report's matrix rows 5 and 6, a foreign
    /// Wi-Fi and a phone hotspot, are precisely where the app cannot know why and the fix is still
    /// the same one.
    static func addExternalAddressAction(
        state: ServerReachability,
        server: JellyfinServer?,
        present: @escaping () -> Void
    ) -> (() -> Void)? {
        #if os(iOS)
        guard state == .offNetwork || state == .unreachable,
              server?.emptyURLSlot == .external
        else { return nil }
        return present
        #else
        return nil
        #endif
    }
}

#if os(iOS)
/// The fix for an off-network server, attached wherever the failure surfaces (Sodalite#122).
///
/// The same single-field sheet the post-login prompt raises, so an address is validated, merged and
/// saved by exactly one path no matter which screen offered it.
private struct AddExternalAddressSheetModifier: ViewModifier {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let server = appState.activeServer, let slot = server.emptyURLSlot {
                AddSecondURLSheet(
                    slot: slot,
                    knownURL: server.url,
                    resolve: ServerAddressResolution.jellyfin(dependencies.serverDiscoveryService),
                    onSave: { newURL in
                        let merged = server.urls(filling: slot, with: newURL)
                        try? dependencies.updateServerURLs(
                            serverID: server.id,
                            internalURL: merged.internal,
                            externalURL: merged.external
                        )
                        // Re-probe at once: the new slot is the whole point, and the verdict it
                        // clears is what put this screen on the display.
                        dependencies.scheduleRouteResolve()
                    }
                )
            }
        }
    }
}
#endif

extension View {
    /// Presents the single-field sheet that fills the server's empty URL slot. iOS only; tvOS has no
    /// URL editor, and there this is the identity.
    func addExternalAddressSheet(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        modifier(AddExternalAddressSheetModifier(isPresented: isPresented))
        #else
        self
        #endif
    }
}
