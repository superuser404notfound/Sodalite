import SwiftUI

/// The Live TV and Music server switcher (Sodalite#85), shaped like the guide's filter chips.
struct ServerChip: View {
    let name: String
    let tint: Color
    let isFocusable: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Label(name, systemImage: "server.rack")
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(1)
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(focused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.Theme.restFillStrong)))
            .focusResponse(.chip, isFocused: focused)
            .focusableSurface(isFocusable)
            .focused($focused)
            .stableTap(isFocused: focused) { action() }
            .fixedSize()
    }
}
