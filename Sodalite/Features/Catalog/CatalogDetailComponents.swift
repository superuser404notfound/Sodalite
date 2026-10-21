import SwiftUI

/// Sub-components extracted from CatalogDetailView; internal, used only within the catalog feature.

/// Season tab in the season selector: picks which season's episodes the page shows below. Requesting
/// is the request sheet's job, so the tab carries no selection state of its own any more (Sodalite#132).
struct CatalogSeasonTab: View {
    let season: SeerrSeason
    let isViewed: Bool
    /// Pipeline status, `nil` when no request exists. Kept distinct (available=green check, processing=blue, pending=orange clock) so "ready to play" reads differently from "waiting for admin approval".
    let availabilityStatus: SeerrMediaStatus?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let status = availabilityStatus {
                    Image(systemName: status.systemImage)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }
                Text(seasonTitle)
                    .font(.body)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(background, in: Capsule())
        }
        .buttonStyle(SeasonChipButtonStyle())
    }

    private var seasonTitle: String {
        let label = String(localized: "catalog.season", defaultValue: "Season")
        return "\(label) \(season.seasonNumber)"
    }

    private var background: some ShapeStyle {
        if isViewed { return AnyShapeStyle(.tint.opacity(0.35)) }
        if let status = availabilityStatus {
            return AnyShapeStyle(status.color.opacity(0.18))
        }
        return AnyShapeStyle(Color.Theme.restFill)
    }
}

struct SeasonChipButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .focusStroke(Capsule(), isFocused: isFocused)
            .focusResponse(.chip, isFocused: isFocused)
    }
}

// MARK: - Picker Button Style

struct CatalogPickerButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .focusStroke(cornerRadius: 12, isFocused: isFocused)
            .focusResponse(.inline, isFocused: isFocused)
    }
}

// MARK: - Option panel chrome

/// Shared chrome for the request option panels: the exits, the title, the scrolling option list and
/// the platform padding.
///
/// The panels used to carry the tvOS Menu press as their only way out, and `onExitCommandCompat` is
/// a no-op on iOS: presented as a cover, which has no interactive dismissal either, the tags panel
/// was a dead end that needed the app force-quit (Sodalite#132). They are presented through
/// `.menuPresentation` now, so iOS also gets a sheet it can swipe away, and Menu on tvOS cancels
/// every one of them.
///
/// Which is why Cancel is an iOS control only: on the Apple TV the remote's own back button is the
/// way out of a panel, so a button repeating it is one more focus stop for nothing (Vincent,
/// 2026-09-09). Done stays on both, because a multi-select has something to confirm that Menu, now
/// a cancel, no longer does.
private struct CatalogOptionPanel<Rows: View>: View {
    let title: Text
    let onCancel: () -> Void
    /// Multi-select only. A single-select panel commits on the row press and has nothing to confirm.
    let onCommit: (() -> Void)?
    @ViewBuilder let rows: () -> Rows

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }
    /// The tvOS card already insets itself off the screen edge, so the panel adds only its own
    /// gutter. Carried by the sections, not the panel: see `SeerrRequestSheet.gutter` for why the
    /// scrolling list has to reach the panel edge while its rows do not.
    private var gutter: CGFloat { isCompact ? 24 : 40 }

    var body: some View {
        VStack(spacing: isCompact ? 18 : 28) {
            exits
                .padding(.horizontal, gutter)
            title
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.semibold)
                .padding(.horizontal, gutter)

            ScrollView {
                VStack(spacing: 12) {
                    rows()
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, gutter)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // tvOS gets its card from the menu cover; a second material here would stack two.
        #if os(iOS)
        .background(.thinMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .onExitCommandCompat { onCancel() }
    }

    @ViewBuilder
    private var exits: some View {
        // A single-select panel on tvOS has no exit control at all, so it gets no row either.
        #if os(iOS)
        HStack(spacing: 16) {
            GlassActionButton(
                title: "common.cancel",
                systemImage: "xmark",
                action: onCancel
            )
            Spacer(minLength: 12)
            commitButton
        }
        #else
        if onCommit != nil {
            HStack(spacing: 16) {
                Spacer(minLength: 12)
                commitButton
            }
        }
        #endif
    }

    @ViewBuilder
    private var commitButton: some View {
        if let onCommit {
            GlassActionButton(
                title: "common.done",
                systemImage: "checkmark",
                isProminent: true,
                action: onCommit
            )
        }
    }
}

/// One option row, shared by the single- and multi-select panels.
private struct CatalogOptionRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Color.Theme.restFill, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CatalogPickerButtonStyle())
    }
}

// MARK: - Picker Sheet

/// Single-select picker for the profile / root-folder dropdowns: a row press adopts the value and
/// closes. Presented as a cover on tvOS (SwiftUI `Menu` leaked the press up the nav stack and exited
/// the app during its close animation), as a sheet on iOS.
struct CatalogPickerSheet: View {
    struct Option: Identifiable {
        let id: String
        let label: String
    }

    let title: Text
    let options: [Option]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focusedID: String?

    init(
        title: String,
        options: [Option],
        selectedID: String?,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.init(title: Text(title), options: options, selectedID: selectedID, onSelect: onSelect, onCancel: onCancel)
    }

    /// For a caller that holds its title as a catalog key (the settings rows).
    init(
        title: LocalizedStringKey,
        options: [Option],
        selectedID: String?,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.init(title: Text(title), options: options, selectedID: selectedID, onSelect: onSelect, onCancel: onCancel)
    }

    private init(
        title: Text,
        options: [Option],
        selectedID: String?,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.options = options
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    var body: some View {
        CatalogOptionPanel(title: title, onCancel: onCancel, onCommit: nil) {
            ForEach(options) { option in
                CatalogOptionRow(
                    label: option.label,
                    isSelected: option.id == selectedID,
                    action: { onSelect(option.id) }
                )
                .focused($focusedID, equals: option.id)
            }
        }
        .onAppear {
            // Focus selected (or first) option so the back-press gap never hits an empty focus.
            focusedID = selectedID ?? options.first?.id
        }
    }
}

// MARK: - Multi-Select Sheet

/// Multi-select sibling of `CatalogPickerSheet`: rows toggle membership, Done commits, Cancel and the
/// tvOS Menu press discard. Used by the Tags picker for one-or-more Sonarr/Radarr labels.
///
/// Menu used to commit here, for want of anything better while the panel had no buttons. With an
/// explicit Done it lines up with every other panel in the app instead.
struct CatalogMultiSelectSheet: View {
    struct Option: Identifiable {
        let id: String
        let label: String
    }

    let title: String
    let options: [Option]
    let selectedIDs: Set<String>
    let onCommit: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var selection: Set<String> = []
    @FocusState private var focusedID: String?

    var body: some View {
        CatalogOptionPanel(
            title: Text(title),
            onCancel: onCancel,
            onCommit: { onCommit(selection) }
        ) {
            ForEach(options) { option in
                CatalogOptionRow(
                    label: option.label,
                    isSelected: selection.contains(option.id),
                    action: { toggle(option.id) }
                )
                .focused($focusedID, equals: option.id)
            }
        }
        .onAppear {
            selection = selectedIDs
            focusedID = options.first?.id
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}
