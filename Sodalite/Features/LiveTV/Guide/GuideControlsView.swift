import SwiftUI

/// Filter chips on the leading side, time targets on the trailing side. Raw `.focusable` surfaces
/// rather than Buttons, matching `PopoverActionButton`: a tvOS Button over this chrome renders only
/// the focused label and leaves the rest as blank tinted pills.
struct GuideControlsView: View {
    let model: GuideViewModel
    let metrics: GuideMetrics
    let tint: Color
    /// False while the player runs and briefly after: the chips must not compete with the grid for
    /// the focus the system restores when the player closes.
    var isFocusable: Bool = true

    @State private var isSearching = false
    @State private var isPickingGenre = false

    /// `detailCover` takes an Identifiable item; the search cover carries no payload of its own.
    private struct SearchRequest: Identifiable { let id = "guide.search" }

    var body: some View {
        HStack(spacing: 12) {
            filterChips
            Spacer(minLength: 20)
            timeTargets
        }
        .padding(.horizontal, 40)
        .frame(height: metrics.controlsHeight)
        .detailCover(item: searchBinding) { _ in
            GuideSearchCover(model: model, tint: tint)
        }
        .menuPresentation(isPresented: $isPickingGenre) {
            GuideGenrePicker(genres: model.genres, tint: tint)
        }
    }

    private var searchBinding: Binding<SearchRequest?> {
        Binding(
            get: { isSearching ? SearchRequest() : nil },
            set: { isSearching = $0 != nil })
    }

    @ViewBuilder
    private var filterChips: some View {
        GuideChip(title: Text("livetv.guide.filter.favorites"),
                  isOn: model.filter.favoritesOnly,
                  tint: tint, isFocusable: isFocusable) {
            var next = model.filter
            next.favoritesOnly.toggle()
            Task { await model.apply(filter: next) }
        }

        ForEach(GuideFilter.Category.allCases) { category in
            GuideChip(title: Text(category.titleKey),
                      isOn: model.filter.category == category,
                      tint: tint, isFocusable: isFocusable) {
                var next = model.filter
                // Tapping the active category clears it, so the chips behave as one radio group
                // with an off state rather than trapping the user in a filter.
                next.category = next.category == category ? nil : category
                Task { await model.apply(filter: next) }
            }
        }

        // Verbatim for the same reason as the search chip: an EPG genre is server data (#182).
        GuideChip(title: model.genres.filter.chipLabel.map { Text(verbatim: $0) }
                    ?? Text("livetv.guide.filter.genre"),
                  isOn: model.genres.filter.isActive,
                  tint: tint, isFocusable: isFocusable) {
            isPickingGenre = true
        }

        if model.hasRadioChannels {
            GuideChip(title: Text("livetv.guide.filter.radio"),
                      isOn: model.filter.kind == .radio,
                      tint: tint, isFocusable: isFocusable) {
                var next = model.filter
                next.kind = next.kind == .radio ? .tv : .radio
                Task { await model.apply(filter: next) }
            }
        }

        // Text(verbatim:), NOT LocalizedStringKey(model.searchText): a runtime string wrapped in a
        // key is looked up in the catalog, so a search for "ARD" would render whatever "ARD"
        // happens to translate to, or the raw key when it misses.
        GuideChip(title: model.searchText.isEmpty
                    ? Text("livetv.guide.filter.search")
                    : Text(verbatim: model.searchText),
                  isOn: !model.searchText.isEmpty,
                  tint: tint, isFocusable: isFocusable) {
            isSearching = true
        }
    }

    @ViewBuilder
    private var timeTargets: some View {
        GuideChip(title: Text("livetv.guide.jump.now"),
                  isOn: false, tint: tint, isFocusable: isFocusable) {
            model.jumpToNow()
        }
        // Both prime-time chips hide when their target is past or outside the axis, rather than
        // offering a jump that does nothing.
        if model.axis.primeTime(days: 0, from: Date()) != nil {
            GuideChip(title: Text("livetv.guide.jump.primetime"),
                      isOn: false, tint: tint, isFocusable: isFocusable) {
                model.jumpToPrimeTime(days: 0)
            }
        }
        if model.axis.primeTime(days: 1, from: Date()) != nil {
            GuideChip(title: Text("livetv.guide.jump.tomorrow"),
                      isOn: false, tint: tint, isFocusable: isFocusable) {
                model.jumpToPrimeTime(days: 1)
            }
        }
    }
}

extension GuideFilter.Category {
    var titleKey: LocalizedStringKey {
        switch self {
        case .sports: "livetv.guide.filter.sports"
        case .kids: "livetv.guide.filter.kids"
        case .news: "livetv.guide.filter.news"
        case .movies: "livetv.guide.filter.movies"
        }
    }
}

/// One control pill. Fills tinted when focused (black label, the app convention), keeps a tinted
/// outline while merely active.
private struct GuideChip: View {
    /// Text, not LocalizedStringKey: the search chip renders the user's live query, which must not
    /// go through the string catalog.
    let title: Text
    let isOn: Bool
    let tint: Color
    var isFocusable: Bool = true
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        // Text only. Ten chips with their SF Symbols overflowed 1840pt of tvOS width and truncated
        // every label ("Favo...", "Nac...", "Morge..."); the icons cost about 360pt for decoration
        // while the words are what is actually read from the couch.
        title
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(1)
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(focused
                    ? AnyShapeStyle(tint)
                    : AnyShapeStyle(isOn ? tint.opacity(0.24) : Color.white.opacity(0.10)))
            )
            .overlay(
                Capsule().strokeBorder(isOn ? tint : Color.clear, lineWidth: focused ? 0 : 2)
            )
            .focusResponse(.chip, isFocused: focused)
            .focusableSurface(isFocusable)
            .focused($focused)
            .stableTap(isFocused: focused) { action() }
    }
}

/// Channel search. Typing narrows the grid live, so dismissing leaves the filter in place and the
/// chip shows the active query.
private struct GuideSearchCover: View {
    let model: GuideViewModel
    let tint: Color

    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("livetv.guide.search.title")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("livetv.guide.search.placeholder", text: $text)
                .font(.title3)
                .verbatimTextEntry()
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.Theme.surfaceElevated))
                .focused($fieldFocused)
                .onChange(of: text) { _, newValue in
                    model.apply(searchText: newValue)
                }

            Text("livetv.guide.search.results \(model.channels.count)")
                .font(.headline)
                .foregroundStyle(.secondary)

            // The prefetch runs in the background, so an early search sees a partial set. Saying so
            // beats letting the user conclude a channel does not exist.
            if !model.channelsComplete {
                Label("livetv.guide.search.loading", systemImage: "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            text = model.searchText
            fieldFocused = true
        }
    }
}
