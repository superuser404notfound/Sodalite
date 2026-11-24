import SwiftUI

/// The library grid's filter menu (Sodalite#252): the groups, and one group's checklist. Edits the
/// grid's draft; the grid applies it when the panel closes. Menu on tvOS (and the back button
/// elsewhere) leaves a checklist for the groups, and the groups for the grid.
struct LibraryFilterSheet: View {
    @Binding var selection: LibraryFilterSelection
    let groups: [LibraryFilterGroup]
    let facets: LibraryFacets?
    let isLoadingFacets: Bool
    let tintColor: Color

    @State private var openGroup: LibraryFilterGroup?
    @FocusState private var focusedRow: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 36) {
            header
            ScrollView {
                LazyVStack(spacing: isCompact ? 12 : 16) {
                    if let openGroup {
                        ForEach(options(for: openGroup)) { option in
                            optionRow(option)
                        }
                    } else {
                        if !selection.isEmpty {
                            actionRow(id: "clear-all", title: String(localized: "library.filter.clearAll")) {
                                selection = LibraryFilterSelection()
                            }
                        }
                        ForEach(groups) { group in
                            groupRow(group)
                        }
                        if isLoadingFacets {
                            ProgressView()
                                .padding(.top, 8)
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(.vertical, 8)
            }
            // A new page starts at its top, not at the scroll offset of the one before.
            .id(openGroup?.rawValue ?? "groups")
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // tvOS gets its card from the menu cover; a second material here would stack two.
        #if os(iOS)
        .background(.thinMaterial)
        #endif
        .onAppear { focusedRow = groups.first.map(groupRowID) }
        // Deeper than the cover's own Menu handler, so it wins while a checklist is open. Only
        // then: installed on the groups page too, it swallowed the press that closes the panel.
        .onExitCommandIfEnabled(openGroup != nil) {
            if let group = openGroup { close(group) }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 16) {
            #if !os(tvOS)
            if let group = openGroup {
                Button { close(group) } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.back"))
            }
            #endif
            Group {
                if let openGroup {
                    Text(openGroup.localizedTitle)
                } else {
                    Text("library.filter.title")
                }
            }
            .font(isCompact ? .title3 : .title2)
            .fontWeight(.semibold)
        }
    }

    private func open(_ group: LibraryFilterGroup) {
        openGroup = group
        focus(options(for: group).first?.id)
    }

    /// Back to the groups, with focus on the group just left.
    private func close(_ group: LibraryFilterGroup) {
        openGroup = nil
        focus(groupRowID(group))
    }

    /// The page swap rebuilds the rows, and an assignment made in the same turn is dropped: focus
    /// fell to the first row, which on the way back is Clear All. One turn later it sticks.
    private func focus(_ id: String?) {
        Task { focusedRow = id }
    }

    private func groupRowID(_ group: LibraryFilterGroup) -> String { "group-\(group.rawValue)" }

    // MARK: - Rows

    private func groupRow(_ group: LibraryFilterGroup) -> some View {
        let id = groupRowID(group)
        let isFocused = focusedRow == id
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.localizedTitle)
                    .font(.body)
                    .fontWeight(.medium)
                Text(summary(for: group))
                    .font(.caption)
                    .lineLimit(1)
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.body)
                .opacity(0.6)
        }
        .rowChrome(isFocused: isFocused, tint: tintColor, compact: isCompact)
        .focused($focusedRow, equals: id)
        .stableTap(isFocused: isFocused) { open(group) }
    }

    private func optionRow(_ option: Option) -> some View {
        let isFocused = focusedRow == option.id
        let isOn = option.isOn(selection)
        return HStack(spacing: 16) {
            Text(option.title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            }
        }
        .rowChrome(isFocused: isFocused, tint: tintColor, compact: isCompact)
        .focused($focusedRow, equals: option.id)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .stableTap(isFocused: isFocused) { option.toggle(&selection) }
    }

    private func actionRow(id: String, title: String, action: @escaping () -> Void) -> some View {
        let isFocused = focusedRow == id
        return HStack {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
            Spacer(minLength: 0)
            Image(systemName: "xmark")
                .font(.body)
        }
        .rowChrome(isFocused: isFocused, tint: tintColor, compact: isCompact)
        .focused($focusedRow, equals: id)
        .stableTap(isFocused: isFocused) {
            action()
            focus(groups.first.map(groupRowID))
        }
    }

    // MARK: - Content

    /// What is picked in a group, in list order, or "Any".
    private func summary(for group: LibraryFilterGroup) -> String {
        let picked = options(for: group).filter { $0.isOn(selection) }.map(\.title)
        guard !picked.isEmpty else { return String(localized: "library.filter.any") }
        return picked.joined(separator: ", ")
    }

    struct Option: Identifiable {
        let id: String
        let title: String
        let isOn: (LibraryFilterSelection) -> Bool
        let toggle: (inout LibraryFilterSelection) -> Void
    }

    private func options(for group: LibraryFilterGroup) -> [Option] {
        switch group {
        case .filters:
            return LibraryStateFilter.allCases.map { value in
                Option(id: "state-\(value.rawValue)", title: Self.localized(value.titleKey),
                       isOn: { $0.states.contains(value) }, toggle: { $0.states.formSymmetricDifference([value]) })
            }
        case .features:
            return LibraryFeatureFilter.allCases.map { value in
                Option(id: "feature-\(value.rawValue)", title: Self.localized(value.titleKey),
                       isOn: { $0.features.contains(value) }, toggle: { $0.features.formSymmetricDifference([value]) })
            }
        case .videoType:
            return LibraryVideoTypeFilter.allCases.map { value in
                Option(id: "video-\(value.rawValue)", title: value.label,
                       isOn: { $0.videoTypes.contains(value) }, toggle: { $0.toggle(value) })
            }
        case .seriesStatus:
            return LibrarySeriesStatusFilter.allCases.map { value in
                Option(id: "status-\(value.rawValue)", title: Self.localized(value.titleKey),
                       isOn: { $0.seriesStatus.contains(value) }, toggle: { $0.seriesStatus.formSymmetricDifference([value]) })
            }
        case .genres:
            return names(facets?.genres, prefix: "genre", keyPath: \.genres)
        case .parentalRatings:
            return names(facets?.officialRatings, prefix: "rating", keyPath: \.officialRatings)
        case .tags:
            return names(facets?.tags, prefix: "tag", keyPath: \.tags)
        case .studios:
            return names(facets?.studios, prefix: "studio", keyPath: \.studios)
        case .years:
            return (facets?.years ?? []).map { year in
                Option(id: "year-\(year)", title: String(year),
                       isOn: { $0.years.contains(year) }, toggle: { $0.years.formSymmetricDifference([year]) })
            }
        case .audioLanguages:
            return languages(facets?.audioLanguages, prefix: "audio", keyPath: \.audioLanguages)
        case .subtitleLanguages:
            return languages(facets?.subtitleLanguages, prefix: "subtitle", keyPath: \.subtitleLanguages)
        }
    }

    private func names(
        _ values: [String]?, prefix: String, keyPath: WritableKeyPath<LibraryFilterSelection, Set<String>>
    ) -> [Option] {
        (values ?? []).map { name in
            Option(id: "\(prefix)-\(name)", title: name,
                   isOn: { $0[keyPath: keyPath].contains(name) },
                   toggle: { $0[keyPath: keyPath].formSymmetricDifference([name]) })
        }
    }

    private func languages(
        _ values: [LanguageFacet]?, prefix: String, keyPath: WritableKeyPath<LibraryFilterSelection, Set<String>>
    ) -> [Option] {
        (values ?? []).map { language in
            Option(id: "\(prefix)-\(language.value)", title: language.name,
                   isOn: { $0[keyPath: keyPath].contains(language.value) },
                   toggle: { $0[keyPath: keyPath].formSymmetricDifference([language.value]) })
        }
    }

    private static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

private extension View {
    /// The sort panel's row: tint on focus, the surface fill at rest.
    func rowChrome(isFocused: Bool, tint: Color, compact: Bool) -> some View {
        self
            .padding(.horizontal, compact ? 18 : 32)
            .padding(.vertical, compact ? 14 : 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? tint : Color.Theme.surface)
            )
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .focusableSurface(true)
    }
}
