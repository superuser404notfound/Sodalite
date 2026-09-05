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

    /// Address advice, and only where an address is the problem. Offering it to someone in airplane
    /// mode is noise, and offering it for a server that already carries a remote address is wrong.
    private var subtitle: Text? {
        switch state {
        case .offNetwork where onAddExternalAddress != nil:
            Text("server.offNetwork.body")
        default:
            nil
        }
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
                .buttonStyle(SettingsTileButtonStyle())
                .disabled(isRetrying)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
