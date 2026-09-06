import SwiftUI

/// Sort picker for the library grids (Sodalite#78). Picking the active key flips its direction,
/// picking another adopts that key's natural one; either way the sheet closes so the grid is visible
/// while it reloads.
struct LibrarySortSheet: View {
    let selection: LibrarySort
    let tintColor: Color
    let onSelect: (LibrarySort) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedKey: LibrarySortKey?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// iPhone (compact) shrinks the tvOS-scaled padding and row heights; tvOS and iPad keep full size.
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 36) {
            Text("library.sort.title")
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(spacing: isCompact ? 12 : 16) {
                    ForEach(LibrarySortKey.allCases, id: \.self) { key in
                        row(key)
                    }
                }
                .frame(maxWidth: 760)
                .padding(.vertical, 8)
            }
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .onAppear { focusedKey = selection.key }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func row(_ key: LibrarySortKey) -> some View {
        let isFocused = focusedKey == key
        let isSelected = selection.key == key
        return HStack(spacing: 16) {
            Text(key.localizedLabel)
                .font(.body)
                .fontWeight(.medium)
            Spacer(minLength: 0)
            if isSelected {
                Text(key.localizedDirection(descending: selection.descending))
                    .font(.caption)
                    .opacity(0.75)
                Image(systemName: selection.descending ? "arrow.down" : "arrow.up")
                    .font(.body)
            }
        }
        .padding(.horizontal, isCompact ? 18 : 32)
        .padding(.vertical, isCompact ? 14 : 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? tintColor : Color.Theme.surface)
        )
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .focusable(true)
        .focused($focusedKey, equals: key)
        .stableTap(isFocused: isFocused) {
            onSelect(selection.toggled(to: key))
            dismiss()
        }
    }
}
