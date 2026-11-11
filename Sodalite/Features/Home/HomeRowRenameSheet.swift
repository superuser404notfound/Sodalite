import SwiftUI

/// Gives a Home row a heading of the user's own (Customize Home). `onSave` gets the new title, nil
/// to go back to the built-in one; dismissing without saving leaves the row as it was.
struct HomeRowRenameSheet: View {
    /// The row's built-in heading, shown as the field's placeholder.
    let originalTitle: Text
    let customTitle: String?
    let onSave: (String?) -> Void

    private enum Slot: Hashable {
        case field, save, reset
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Slot?
    @State private var text = ""

    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 36) {
            Text("home.customize.rename.title")
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.semibold)

            TextField("home.customize.rename.title", text: $text, prompt: originalTitle)
                .font(isCompact ? .body : .title3)
                #if !os(macOS)
                .textInputAutocapitalization(.words)
                #endif
                .submitLabel(.done)
                .padding(isCompact ? 12 : 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.Theme.surfaceElevated))
                .frame(maxWidth: isCompact ? .infinity : 900)
                .focused($focused, equals: .field)
                .onSubmit(save)

            HStack(spacing: isCompact ? 12 : 24) {
                button("common.save", systemImage: "checkmark", slot: .save, action: save)
                if customTitle != nil {
                    button("home.customize.rename.reset", systemImage: "arrow.uturn.backward", slot: .reset) {
                        onSave(nil)
                        dismiss()
                    }
                }
            }
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(.thinMaterial)
        .presentationDetents([.medium])
        #endif
        .onAppear {
            text = customTitle ?? ""
            focused = .field
        }
    }

    private func save() {
        onSave(HomeRowConfig.sanitizedTitle(text))
        dismiss()
    }

    private func button(
        _ title: LocalizedStringKey, systemImage: String, slot: Slot, action: @escaping () -> Void
    ) -> some View {
        let isFocused = focused == slot
        return Label(title, systemImage: systemImage)
            .font(.body.weight(.medium))
            .padding(.horizontal, isCompact ? 18 : 32)
            .padding(.vertical, isCompact ? 12 : 18)
            .background(Capsule().fill(isFocused ? Color.white : Color.Theme.restFill))
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .focusableSurface(true)
            .focused($focused, equals: slot)
            .stableTap(isFocused: isFocused, perform: action)
    }
}

/// Drives the rename panel via `.menuPresentation(item:)`.
struct HomeRowRenameTarget: Identifiable {
    let id: String
}
