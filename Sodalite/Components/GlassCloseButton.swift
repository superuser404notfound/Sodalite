#if os(iOS)
import SwiftUI

/// The iOS close button of covers and sheets that draw their own: a glass circle with the cross in
/// the accent, the way the system's toolbar close button (the profile picker's) renders it, so every
/// "close" in the app looks the same.
struct GlassCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(12)
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
#endif
