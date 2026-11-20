import SwiftUI

/// Genre selection for the guide and the iPhone channel list (#182). Toggling a genre applies at
/// once, so the list behind the panel is already narrowed when it closes; several genres combine as
/// OR.
struct GuideGenrePicker: View {
    let genres: GuideGenreController
    let tint: Color

    @FocusState private var focusedRow: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }

    /// The row id for "All genres", which no EPG genre can collide with: names never start with a
    /// control character.
    private static let allRowID = "\u{1}all"

    private var scope: GuideGenreFilter.Scope { genres.filter.scope }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 32) {
            Text("livetv.guide.genre.title")
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                ForEach(GuideGenreFilter.Scope.allCases) { option in
                    scopeButton(option)
                }
            }

            content
                .frame(maxWidth: 760, maxHeight: .infinity)
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // tvOS gets its card from the menu cover; a second material here would stack two.
        #if os(iOS)
        .background(.thinMaterial)
        .presentationDetents([.medium, .large])
        #endif
        .task(id: scope) { await genres.loadNames(for: scope) }
    }

    @ViewBuilder
    private var content: some View {
        if let names = genres.names[scope] {
            if names.isEmpty {
                ContentUnavailableView("livetv.guide.genre.empty", systemImage: "tag.slash")
            } else {
                VStack(spacing: 16) {
                    // A failed match drops the selection; this says why the grid did not narrow.
                    if let error = genres.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    list(names)
                }
            }
        } else if let error = genres.error, genres.loadingScope == nil {
            ContentUnavailableView {
                Label("livetv.loadFailed.title", systemImage: "tv.slash")
            } description: {
                Text(error)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ names: [String]) -> some View {
        ScrollView {
            LazyVStack(spacing: isCompact ? 12 : 16) {
                row(id: Self.allRowID, title: Text("livetv.guide.genre.all"),
                    isSelected: !genres.filter.isActive) {
                    select([])
                }
                // A selected genre that is not on offer in this scope stays listed, or it could
                // not be switched off from here.
                ForEach(listed(names), id: \.self) { name in
                    // Verbatim: an EPG genre is server data, not a catalog key.
                    row(id: name, title: Text(verbatim: name.epgDisplayText),
                        isSelected: genres.filter.genres.contains(name)) {
                        var selection = genres.filter.genres
                        if selection.contains(name) { selection.remove(name) } else { selection.insert(name) }
                        select(selection)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            focusedRow = genres.filter.genres.sorted().first ?? Self.allRowID
        }
    }

    private func listed(_ names: [String]) -> [String] {
        let missing = genres.filter.genres.filter { !names.contains($0) }
        guard !missing.isEmpty else { return names }
        return (names + missing).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func select(_ selection: Set<String>) {
        var next = genres.filter
        next.genres = selection
        Task { await genres.apply(next) }
    }

    private func row(id: String, title: Text, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        let isFocused = focusedRow == id
        return HStack(spacing: 16) {
            title
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, isCompact ? 18 : 32)
        .padding(.vertical, isCompact ? 14 : 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? tint : Color.Theme.surface)
        )
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .focusable(true)
        .focused($focusedRow, equals: id)
        .stableTap(isFocused: isFocused, perform: action)
    }

    private func scopeButton(_ option: GuideGenreFilter.Scope) -> some View {
        let id = "\u{1}scope.\(option.rawValue)"
        let isFocused = focusedRow == id
        let isOn = scope == option
        return Text(option.titleKey)
            .font(.callout)
            .fontWeight(.semibold)
            .lineLimit(1)
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(isFocused
                    ? AnyShapeStyle(tint)
                    : AnyShapeStyle(isOn ? tint.opacity(0.24) : Color.Theme.restFill))
            )
            .overlay(Capsule().strokeBorder(isOn ? tint : Color.clear, lineWidth: isFocused ? 0 : 2))
            .focusable(true)
            .focused($focusedRow, equals: id)
            .stableTap(isFocused: isFocused) {
                guard !isOn else { return }
                var next = genres.filter
                next.scope = option
                Task { await genres.apply(next) }
            }
    }
}

extension GuideGenreFilter.Scope {
    var titleKey: LocalizedStringKey {
        switch self {
        case .now: "livetv.guide.genre.scope.now"
        case .guide: "livetv.guide.genre.scope.guide"
        }
    }
}

extension GuideGenreFilter {
    /// The chip's label: the genre itself, or the first one and how many more.
    var chipLabel: String? {
        let sorted = genres.map(\.epgDisplayText)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = sorted.first else { return nil }
        let head = first.count > 18 ? String(first.prefix(17)) + "\u{2026}" : first
        return sorted.count == 1 ? head : "\(head) +\(sorted.count - 1)"
    }
}
