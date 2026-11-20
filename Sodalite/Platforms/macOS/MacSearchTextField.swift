import SwiftUI

/// The Mac's `SearchTextField`: same name and bindings as the UIKit one, so `SearchView` builds its
/// bar the same way on every platform.
///
/// Plain SwiftUI, because none of the reasons the other platforms drop to UIKit apply here. The
/// UITextField is there for the focus engine, which the Mac does not have, and for a keyboard
/// overlay it raises, which on a Mac is simply the keyboard. A `TextField` behaves like a Mac text
/// field already, Escape and the services menu included.
struct SearchTextField: View {
    @Binding var text: String
    var placeholder: String

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(text: $text) {
            Text(placeholder)
        }
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFocused)
        // The tab exists to be typed into, and it is reached by clicking it, so nothing else here
        // is a better first responder.
        .onAppear { isFocused = true }
        .overlay(alignment: .trailing) {
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("search.clear"))
            }
        }
    }
}
