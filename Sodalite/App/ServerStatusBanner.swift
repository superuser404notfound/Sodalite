import SwiftUI

/// What the app says over content that is still on screen after the server stopped answering
/// (Sodalite#126).
///
/// The verdict is measured once for the whole app, but until now it was only ever consumed at first
/// load: `ServerReachability.blockingState` returns nil the moment anything has painted, which is
/// deliberate, since content that arrived outranks a probe that asked one endpoint. The consequence
/// was that a session which left the network mid-browse kept browsing as though nothing had changed,
/// and the first hard stop was Play.
///
/// The fix is not to put the error screen over painted rows. That throws away a feed the reader can
/// still use, it undoes the point of the shelf painted from disk in Sodalite#117, and once offline
/// downloads land (#81) an error wall in front of a device holding four downloaded episodes would be
/// a worse bug than the one this replaces. So the content stays and the app annotates it.
///
/// No copy here claims the absence is total, and none of it describes what IS on screen: this strip
/// appears over a browsable Home and over an empty Search alike, so a line like "showing what was
/// loaded earlier" would be false half the time it is drawn.
struct ServerStatusBanner: View {
    let state: ServerReachability
    let serverName: String
    /// iOS only, and measured rather than assumed (Wohnzimmer, tvOS 26.6, 2026-09-06): a button in
    /// a bottom safe-area inset does not take focus there, so on tvOS it rendered as a control that
    /// could not be reached, which is worse than no control at all.
    ///
    /// Nothing is lost by dropping it. The app re-measures on its own now, on a failed request and
    /// then on a watch that keeps asking while the answer is bad, so this was never the way back,
    /// only the way to stop waiting for the next check. Anyone tempted to re-add it here should fix
    /// the reachability first, not the platform check.
    let onRetry: (() async -> Void)?

    @State private var isRetrying = false

    private var symbol: String {
        switch state {
        case .noNetwork: "wifi.slash"
        default: "network.slash"
        }
    }

    /// The same sentence the full screen says, so the two cannot drift into two accounts of one
    /// fact. Which one is picked is the verdict's business, not this view's.
    private var line: Text {
        switch state {
        case .noNetwork:
            Text("server.noNetwork.title")
        case .offNetwork:
            Text("server.offNetwork.title \(serverName)")
        default:
            Text("server.unreachable.title \(serverName)")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)

            line
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onRetry {
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
                            Text("home.retry").font(.footnote).fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(SettingsTileButtonStyle(isProminent: true))
                .disabled(isRetrying)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Raised by the screen that is already showing the full unreachable state, so the strip does not
/// stand under a screen saying the same thing.
///
/// A preference rather than shared state: only the screen itself knows whether its content painted,
/// and that answer has to travel up to the one place the strip is applied. `false` beats `true` on
/// reduce, so a single screen claiming the display silences the strip for the tab it is in.
struct ServerUnreachableScreenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct ServerStatusBannerModifier: ViewModifier {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var fullScreenIsShowing = false

    /// Nothing to say, or something better already saying it.
    private var bannerState: ServerReachability? {
        appState.serverReachability.bannerState(fullScreenIsShowing: fullScreenIsShowing)
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ServerUnreachableScreenKey.self) { isShowing in
                // Hopped rather than assigned: the preference callback is not MainActor-isolated,
                // and a Bool is the whole payload.
                Task { @MainActor in fullScreenIsShowing = isShowing }
            }
            .safeAreaInset(edge: .bottom) {
                if let bannerState {
                    ServerStatusBanner(
                        state: bannerState,
                        serverName: appState.activeServer?.name ?? "",
                        onRetry: retryAction
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: bannerState)
    }

    /// Only the probe is awaited. A verdict that improves already bumps `requestContentReload` from
    /// `publishReachability`, so the reload needs no wiring here, and awaiting the fetch would put
    /// the multi-minute spin back that Sodalite#122 removed.
    private var retryAction: (() async -> Void)? {
        #if os(iOS)
        { await dependencies.retryAfterFailure() }
        #else
        nil
        #endif
    }
}

extension View {
    /// Annotates a tab's content with the server verdict where the content itself cannot
    /// (Sodalite#126). Applied once, on the tab content, because the fact is app-wide.
    func serverStatusBanner() -> some View {
        modifier(ServerStatusBannerModifier())
    }
}
