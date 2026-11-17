#if os(iOS)
import SwiftUI

/// Single-field URL sheet shown after login to add the missing internal/external
/// address. Mirrors DualURLEditSheet's resolve + save-anyway behavior but for
/// exactly one slot; the already-known address is shown read-only for context.
struct AddSecondURLSheet: View {
    let slot: ServerRoute
    let knownURL: URL
    let resolve: ServerAddressResolution.Discover
    let onSave: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var isValidating = false
    @State private var validationError: LocalizedStringKey?
    @State private var showUnreachableConfirm = false
    @State private var unreachableHost = ""
    /// What the last validation pass decided to store, kept so the confirmation
    /// dialog saves the resolved address rather than re-reading the field.
    @State private var pendingURL: URL?

    private var title: LocalizedStringKey {
        slot == .internal ? "multiServer.addURL.sheet.title.internal" : "multiServer.addURL.sheet.title.external"
    }
    private var placeholder: LocalizedStringKey {
        slot == .internal ? "multiServer.urls.internal.placeholder" : "multiServer.urls.external.placeholder"
    }

    var body: some View {
        ThemeNavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(knownURL.host() ?? knownURL.absoluteString)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("multiServer.addURL.knownLabel", bundle: .main)
                    }
                }
                Section {
                    TextField(placeholder, text: $urlText)
                        .verbatimTextEntry(.url)
                        .disabled(isValidating)
                } footer: {
                    Text("multiServer.addURL.footer", bundle: .main)
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
                Text("multiServer.urls.unreachable.message \(unreachableHost)", bundle: .main)
            }
        }
        .themedPresentationBackground()
    }

    private func validateAndSave() async {
        validationError = nil
        isValidating = true
        defer { isValidating = false }

        let typed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await ServerAddressResolution.resolve(urlText, discover: resolve) {
        case .empty:
            validationError = "multiServer.urls.atLeastOne"
        case .unresolved:
            validationError = "multiServer.urls.invalid \(typed)"
        case .otherServer(let url):
            validationError = "multiServer.urls.otherServer \(url.host() ?? url.absoluteString)"
        case .resolved(let url):
            pendingURL = url
            // Show what discovery settled on rather than the shorthand that produced it.
            urlText = url.absoluteString
            commit()
        case .unreachable(let url):
            pendingURL = url
            unreachableHost = url.host() ?? url.absoluteString
            showUnreachableConfirm = true
        }
    }

    private func commit() {
        guard let pendingURL else { return }
        onSave(pendingURL)
        dismiss()
    }
}
#endif
