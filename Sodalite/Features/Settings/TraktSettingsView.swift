import CoreImage.CIFilterBuiltins
import SwiftUI

/// Connects the active profile to Trakt with a device code, and holds the switches for what the
/// connection does. Per profile and per device: each box signs in on its own.
struct TraktSettingsView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    @State private var deviceCode: TraktDeviceCode?
    @State private var signInTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var serverHasPlugin: Bool?

    private var trakt: TraktService { dependencies.trakt }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Text("settings.trakt.title")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                if let session = trakt.session {
                    connected(session)
                } else if let deviceCode {
                    codePanel(deviceCode)
                } else {
                    disconnected
                }

                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(Color.Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                Text("trakt.attribution")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .screenContentInset()
        }
        .animation(.easeInOut(duration: 0.3), value: trakt.isConnected)
        .animation(.easeInOut(duration: 0.3), value: deviceCode)
        .hidesShellTabBar()
        .hidesNavigationBarChrome()
        .task {
            guard appState.activeUser?.policy?.isAdministrator == true else { return }
            serverHasPlugin = await dependencies.activeServerHasTraktPlugin()
        }
        .onDisappear {
            signInTask?.cancel()
            signInTask = nil
        }
    }

    // MARK: - Disconnected

    private var disconnected: some View {
        VStack(spacing: 24) {
            Text("trakt.intro")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            pluginNote

            Button(action: startSignIn) {
                Label("trakt.connect", systemImage: "link")
                    .font(.body)
                    .fontWeight(.medium)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
    }

    @ViewBuilder
    private var pluginNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: serverHasPlugin == true ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(serverHasPlugin == true ? AnyShapeStyle(Color.Theme.destructive) : AnyShapeStyle(.secondary))
            Text(serverHasPlugin == true ? "trakt.plugin.detected" : "trakt.plugin.note")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.Theme.restFillFaint))
    }

    // MARK: - Device code

    private func codePanel(_ code: TraktDeviceCode) -> some View {
        VStack(spacing: 24) {
            Text("trakt.code.instructions \(code.verificationUrl)")
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(code.userCode)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .tracking(6)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif

            #if os(tvOS)
            if let image = Self.qrImage(for: "\(code.verificationUrl)/\(code.userCode)") {
                Image(platformImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            }
            #else
            if let url = URL(string: "\(code.verificationUrl)/\(code.userCode)") {
                Link(destination: url) {
                    Label("trakt.code.open", systemImage: "safari")
                        .font(.body)
                        .fontWeight(.medium)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
            #endif

            HStack(spacing: 12) {
                ProgressView()
                Text("trakt.code.waiting")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button(role: .cancel) {
                cancelSignIn()
            } label: {
                Text("common.cancel")
                    .font(.body)
                    .fontWeight(.medium)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
    }

    private func startSignIn() {
        errorText = nil
        signInTask?.cancel()
        signInTask = Task {
            do {
                let code = try await trakt.requestDeviceCode()
                try Task.checkCancellation()
                deviceCode = code
                try await trakt.completeDeviceSignIn(code)
            } catch {
                // A cancelled attempt leaves the screen alone: a newer one may already own it.
                if error is CancellationError || Task.isCancelled { return }
                errorText = ErrorText.user(for: error)
            }
            deviceCode = nil
            signInTask = nil
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        deviceCode = nil
    }

    // MARK: - Connected

    private func connected(_ session: TraktSession) -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.Theme.success)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: session.username)
                        .font(.body)
                        .fontWeight(.medium)
                    if session.isVIP {
                        Text("trakt.vip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.Theme.restFillFaint))

            if serverHasPlugin == true { pluginNote }

            toggle(icon: "dot.radiowaves.left.and.right", title: "trakt.option.scrobble.title",
                   subtitle: "trakt.option.scrobble.subtitle", keyPath: \.scrobble)
            toggle(icon: "checkmark.circle", title: "trakt.option.syncWatched.title",
                   subtitle: "trakt.option.syncWatched.subtitle", keyPath: \.syncWatched)
            toggle(icon: "star", title: "trakt.option.syncRatings.title",
                   subtitle: "trakt.option.syncRatings.subtitle", keyPath: \.syncRatings)

            syncStatus(session)

            HStack(spacing: 16) {
                Button {
                    trakt.sync(force: true)
                } label: {
                    Label("trakt.sync.now", systemImage: "arrow.triangle.2.circlepath")
                        .font(.body)
                        .fontWeight(.medium)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
                .disabled(trakt.isSyncing)

                Button {
                    Task { await trakt.disconnect() }
                } label: {
                    Label("trakt.disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.body)
                        .fontWeight(.medium)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
        }
    }

    private func toggle(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
                        keyPath: WritableKeyPath<TraktOptions, Bool>) -> some View {
        ValuePickerRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            options: [true, false],
            selection: Binding(
                get: { trakt.session?.options[keyPath: keyPath] ?? true },
                set: { value in trakt.updateOptions { $0[keyPath: keyPath] = value } }
            ),
            label: { $0
                ? String(localized: "common.on", defaultValue: "On")
                : String(localized: "common.off", defaultValue: "Off") }
        )
    }

    @ViewBuilder
    private func syncStatus(_ session: TraktSession) -> some View {
        VStack(spacing: 6) {
            if trakt.isSyncing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("trakt.sync.running")
                }
            } else if let last = session.cursors.lastSyncAt {
                Text("trakt.sync.last \(last.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("trakt.sync.never")
            }
            if let error = trakt.lastSyncError {
                Text(verbatim: error)
                    .foregroundStyle(Color.Theme.destructive)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    #if os(tvOS)
    /// Same recipe as the log export panel: M correction, nearest-neighbour scaling, white quiet zone.
    private static func qrImage(for text: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return PlatformImage.wrapping(cgImage, size: scaled.extent.size)
    }
    #endif
}
