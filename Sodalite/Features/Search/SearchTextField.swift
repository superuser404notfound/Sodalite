#if os(iOS)
// The iOS search field. tvOS uses InlineSearchContainer, macOS SwiftUI's own field.
import SwiftUI
import UIKit

/// UIKit UITextField wrapper with UIKit's own clear button.
struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        // 26pt keeps the inline bar slim.
        field.font = UIFont.systemFont(ofSize: 26, weight: .regular)
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // UIKit draws the clear button inside the field at the trailing edge, where iOS looks for
        // it, and localizes and voices it for free. .always rather than .whileEditing so it survives
        // the keyboard being dismissed, which is exactly when a stale query is in the way.
        field.clearButtonMode = .always
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        context.coordinator.parent = self
        if !isEditing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        } else if isEditing && !uiView.isFirstResponder && uiView.window != nil {
            // Sodalite#209: a second tap on the Search tab asks for the keyboard.
            uiView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isEditing { parent.isEditing = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isEditing { parent.isEditing = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        /// The clear button does not post .editingChanged, so the binding is published here or the
        /// field empties while the results below keep showing the old query's hits.
        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            parent.text = ""
            return true
        }
    }
}
#endif
