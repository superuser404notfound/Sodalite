import SwiftUI

/// The library grid's filter menu (Sodalite#252): the groups, and one group's checklist. Edits the
/// grid's draft; the grid applies it when the panel closes. Menu on tvOS (and the back button
/// elsewhere) leaves a checklist for the groups, and the groups for the grid. Play/Pause on tvOS
/// and Done elsewhere close it from either page.
struct LibraryFilterSheet: View {
    @Binding var selection: LibraryFilterSelection
    let groups: [LibraryFilterGroup]
    let facets: LibraryFacets?
    let isLoadingFacets: Bool
    let tintColor: Color

    @State private var openGroup: LibraryFilterGroup?
    /// The open group's rows, built once when it opens. Rebuilt in `body` they cost a pass over the
    /// whole list on every focus step: 13 ms for 30,000 tags in the tvOS simulator, several times
    /// that on an Apple TV.
    @State private var groupOptions: [Option] = []
    /// `groupOptions` narrowed by `searchText`, kept for the same reason.
    @State private var shownOptions: [Option] = []
    /// `groupOptions` titles folded for search, built on the first search in a group.
    @State private var searchKeys: [String] = []
    /// Width of the header's trailing control, so a long title truncates before it reaches it.
    @State private var headerSideWidth: CGFloat = 0
    @State private var searchText = ""
    @FocusState private var focusedRow: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 36) {
            header
            if openGroup != nil && isSearchable {
                searchField
            }
            ScrollView {
                LazyVStack(spacing: isCompact ? 12 : 16) {
                    if openGroup != nil {
                        ForEach(shownOptions) { option in
                            optionRow(option)
                        }
                        if shownOptions.isEmpty && !searchText.isEmpty {
                            Text("search.empty.noResults")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
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
        .onAppear { focus(groups.first.map(groupRowID)) }
        // Deeper than the cover's own Menu handler, so it wins while a checklist is open. Only
        // then: installed on the groups page too, it swallowed the press that closes the panel.
        .onExitCommandIfEnabled(openGroup != nil) {
            if let group = openGroup { close(group) }
        }
        // The way out from a checklist without two Menu presses. Closing applies the draft.
        .onPlayPauseCommandCompat { dismiss() }
        .onChange(of: searchText) { _, _ in narrowOptions() }
        // Facets are written once today; this keeps an open checklist honest if that changes.
        .onChange(of: facets) { _, _ in
            guard let openGroup else { return }
            groupOptions = options(for: openGroup)
            searchKeys = []
            narrowOptions()
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var header: some View {
        Group {
            if let openGroup {
                Text(openGroup.localizedTitle)
            } else {
                Text("library.filter.title")
            }
        }
        .font(isCompact ? .title3 : .title2)
        .fontWeight(.semibold)
        .lineLimit(1)
        // Keeps a long title clear of Back and Done. It truncates instead of running under them.
        .padding(.horizontal, headerSideWidth + (isCompact ? 12 : 24))
        .frame(maxWidth: 760)
        .overlay(alignment: .leading) {
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
        }
        .overlay(alignment: .trailing) {
            #if os(tvOS)
            // Not a focus stop. On a long checklist a button up here would be a long way off.
            Label {
                Text("common.done")
            } icon: {
                Image(systemName: "playpause.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerSideWidth = $0 }
            #else
            Button("common.done") { dismiss() }
                .fontWeight(.semibold)
                .buttonStyle(.plain)
                .foregroundStyle(tintColor)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerSideWidth = $0 }
            #endif
        }
    }

    /// Long lists get a search field. The threshold is about a screenful of rows.
    private var isSearchable: Bool { groupOptions.count >= Self.searchThreshold }
    static let searchThreshold = 15
    private static let searchRowID = "search"

    private var searchField: some View {
        TextField("search.placeholder", text: $searchText)
            .font(.body)
            .verbatimTextEntry()
            // tvOS draws its own field; a fill around it showed as a second frame.
            #if !os(tvOS)
            .padding(isCompact ? 12 : 16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.Theme.surfaceElevated))
            #endif
            .frame(maxWidth: 760)
            .focused($focusedRow, equals: Self.searchRowID)
    }

    private func narrowOptions() {
        if !searchText.isEmpty, searchKeys.count != groupOptions.count {
            searchKeys = Self.searchKeys(for: groupOptions)
        }
        shownOptions = Self.narrowed(groupOptions, keys: searchKeys, by: searchText)
    }

    /// Titles folded once per group, so each keystroke is a plain substring test per row instead
    /// of an ICU comparison over thousands of names.
    static func searchKeys(for options: [Option]) -> [String] {
        options.map { fold($0.title) }
    }

    /// Case and accent blind, anywhere in the name. "amelie" finds "Amélie", "noir" finds "neo-noir".
    static func narrowed(_ options: [Option], keys: [String], by text: String) -> [Option] {
        let needle = fold(text.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty, keys.count == options.count else { return options }
        return zip(options, keys).filter { $0.1.contains(needle) }.map(\.0)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private func open(_ group: LibraryFilterGroup) {
        searchText = ""
        groupOptions = options(for: group)
        searchKeys = []
        shownOptions = groupOptions
        openGroup = group
        // A long list starts on its search field, the quickest way into it.
        focus(isSearchable ? Self.searchRowID : groupOptions.first?.id)
    }

    /// Back to the groups, with focus on the group just left.
    private func close(_ group: LibraryFilterGroup) {
        openGroup = nil
        searchText = ""
        groupOptions = []
        searchKeys = []
        shownOptions = []
        focus(groupRowID(group))
    }

    /// The page swap rebuilds the rows, and an assignment made in the same turn is dropped: focus
    /// fell to the first row, which on the way back is Clear All. One turn later it sticks.
    ///
    /// On iOS and macOS only when a row already has focus, which means a keyboard is driving the
    /// panel. On a touch screen a row focused from code wore the accent fill and read as a second,
    /// wrong selection next to the tick.
    private func focus(_ id: String?) {
        #if !os(tvOS)
        guard focusedRow != nil else { return }
        #endif
        Task { focusedRow = id }
    }

    private func groupRowID(_ group: LibraryFilterGroup) -> String { "group-\(group.rawValue)" }

    // MARK: - Rows

    private func groupRow(_ group: LibraryFilterGroup) -> some View {
        let id = groupRowID(group)
        let isFocused = focusedRow == id
        let picked = summary(for: group)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.localizedTitle)
                    .font(.body)
                    .fontWeight(.medium)
                // A group that narrows the grid shows its picks in the accent. On a focused row
                // the row itself is the accent, so the text keeps the row's colour there.
                Text(picked ?? String(localized: "library.filter.any"))
                    .font(.caption)
                    .lineLimit(1)
                    .modifier(AccentWhen(isOn: picked != nil && !isFocused, tint: tintColor))
                    .opacity(picked == nil ? 0.75 : 1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.body)
                .opacity(0.6)
        }
        .libraryPanelRow(isFocused: isFocused, tint: tintColor, compact: isCompact)
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
        .libraryPanelRow(isFocused: isFocused, tint: tintColor, compact: isCompact)
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
        .libraryPanelRow(isFocused: isFocused, tint: tintColor, compact: isCompact)
        .focused($focusedRow, equals: id)
        .stableTap(isFocused: isFocused) {
            action()
            focus(groups.first.map(groupRowID))
        }
    }

    // MARK: - Content

    /// What is picked in a group, or nil for "Any". Built from the picks, not by walking the facet
    /// lists. A library can carry tens of thousands of tags, and this runs per row per redraw.
    private func summary(for group: LibraryFilterGroup) -> String? {
        let picked: [String]
        switch group {
        case .genres: picked = Self.sortedNames(selection.genres)
        case .parentalRatings: picked = Self.sortedNames(selection.officialRatings)
        case .tags: picked = Self.sortedNames(selection.tags)
        case .studios: picked = Self.sortedNames(selection.studios)
        case .years: picked = selection.years.sorted(by: >).map(String.init)
        case .audioLanguages:
            picked = (facets?.audioLanguages ?? []).filter { selection.audioLanguages.contains($0.value) }.map(\.name)
        case .subtitleLanguages:
            picked = (facets?.subtitleLanguages ?? []).filter { selection.subtitleLanguages.contains($0.value) }.map(\.name)
        case .filters, .features, .videoType, .seriesStatus:
            picked = options(for: group).filter { $0.isOn(selection) }.map(\.title)
        }
        guard !picked.isEmpty else { return nil }
        return picked.joined(separator: ", ")
    }

    private static func sortedNames(_ names: Set<String>) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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

/// The accent on a view when `isOn`, otherwise whatever foreground the view already inherits.
private struct AccentWhen: ViewModifier {
    let isOn: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if isOn {
            content.foregroundStyle(tint)
        } else {
            content
        }
    }
}
