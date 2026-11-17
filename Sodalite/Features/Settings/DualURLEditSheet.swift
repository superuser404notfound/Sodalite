#if os(iOS)
import SwiftUI

/// Two-slot URL editor shared by Jellyfin server management and Seerr
/// settings. Saving resolves each entry through the same discovery the setup
/// screens use, so a bare "192.168.1.10" is as complete here as it is there
/// (Sodalite#83); an address nobody answers raises a save-anyway confirmation
/// instead of blocking, because the slot being edited may live on a network
/// this device cannot currently see.
struct DualURLEditSheet: View {
    let title: LocalizedStringKey
    let internalPlaceholder: LocalizedStringKey
    let externalPlaceholder: LocalizedStringKey
    let initialInternalURL: URL?
    let initialExternalURL: URL?
    let resolve: ServerAddressResolution.Discover
    let onSave: (URL?, URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var internalText: String = ""
    @State private var externalText: String = ""
    @State private var isValidating = false
    @State private var validationError: LocalizedStringKey?
    @State private var unreachableHosts: [String] = []
    @State private var showUnreachableConfirm = false
    /// What the last validation pass decided to store, kept so the confirmation
    /// dialog saves the resolved addresses rather than re-reading the fields.
    @State private var pendingInternalURL: URL?
    @State private var pendingExternalURL: URL?

    var body: some View {
        ThemeNavigationStack {
            Form {
                Section {
                    TextField(internalPlaceholder, text: $internalText)
                        .verbatimTextEntry(.url)
                        .disabled(isValidating)
                } header: {
                    Text("multiServer.urls.internal", bundle: .main)
                }
                Section {
                    TextField(externalPlaceholder, text: $externalText)
                        .verbatimTextEntry(.url)
                        .disabled(isValidating)
                } header: {
                    Text("multiServer.urls.external", bundle: .main)
                } footer: {
                    Text("multiServer.urls.footer", bundle: .main)
                }
                if let validationError {
                    Section {
                        Text(validationError, bundle: .main)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(Text(title, bundle: .main))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isValidating {
                        ProgressView()
                    } else {
                        Button("common.save") { Task { await validateAndSave() } }
                    }
                }
            }
            .interactiveDismissDisabled(isValidating)
            .confirmationDialog(
                Text("multiServer.urls.unreachable.title", bundle: .main),
                isPresented: $showUnreachableConfirm,
                titleVisibility: .visible
            ) {
                Button("multiServer.urls.saveAnyway") { commit() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("multiServer.urls.unreachable.message \(unreachableHosts.joined(separator: ", "))", bundle: .main)
            }
            .onAppear {
                internalText = initialInternalURL?.absoluteString ?? ""
                externalText = initialExternalURL?.absoluteString ?? ""
            }
        }
        .themedPresentationBackground()
    }

    private func validateAndSave() async {
        validationError = nil
        isValidating = true
        defer { isValidating = false }

        async let internalWork = ServerAddressResolution.resolve(internalText, discover: resolve)
        async let externalWork = ServerAddressResolution.resolve(externalText, discover: resolve)
        let (internalOutcome, externalOutcome) = await (internalWork, externalWork)

        var slots: [URL?] = []
        var unanswered: [String] = []
        for (text, outcome) in [(internalText, internalOutcome), (externalText, externalOutcome)] {
            switch outcome {
            case .empty:
                slots.append(nil)
            case .resolved(let url):
                slots.append(url)
            case .unreachable(let url):
                slots.append(url)
                unanswered.append(url.host() ?? url.absoluteString)
            case .unresolved:
                // Name the field that failed: with two of them, "that address" is a guess.
                validationError = "multiServer.urls.invalid \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
                return
            case .otherServer(let url):
                validationError = "multiServer.urls.otherServer \(url.host() ?? url.absoluteString)"
                return
            }
        }
        guard slots.contains(where: { $0 != nil }) else {
            validationError = "multiServer.urls.atLeastOne"
            return
        }

        pendingInternalURL = slots[0]
        pendingExternalURL = slots[1]
        // Show what discovery settled on, so a cancelled confirmation leaves the
        // resolved address in the field rather than the shorthand that produced it.
        if case .resolved(let url) = internalOutcome { internalText = url.absoluteString }
        if case .resolved(let url) = externalOutcome { externalText = url.absoluteString }

        if unanswered.isEmpty {
            commit()
        } else {
            unreachableHosts = unanswered
            showUnreachableConfirm = true
        }
    }

    private func commit() {
        onSave(pendingInternalURL, pendingExternalURL)
        dismiss()
    }
}
#endif
