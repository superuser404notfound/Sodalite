import SwiftUI

private struct ChannelSelection: Identifiable {
    let channel: JellyfinChannel
    var id: String { channel.id }
}

private struct ChannelProgramSelection: Identifiable {
    let channel: JellyfinChannel
    let program: JellyfinProgram
    var id: String { "\(channel.id)-\(program.id)" }
}

/// Live TV on the phone. A 2D grid behind a channel column does not fit 393pt, so compact gets a
/// list that answers "what is on now" directly and defers the timeline to a per-channel sheet.
struct ChannelListView: View {
    @State private var model: ChannelListViewModel
    let tint: Color
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    @State private var searchText = ""
    @State private var channelSelection: ChannelSelection?

    init(model: ChannelListViewModel,
         tint: Color,
         onWatchLive: ((LivePlaybackContext) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.tint = tint
        self.onWatchLive = onWatchLive
    }

    var body: some View {
        content
            .onChange(of: searchText) { _, newValue in model.apply(searchText: newValue) }
            .task { await model.load() }
            .sheet(item: $channelSelection) { selected in
                ChannelScheduleSheet(model: model, channel: selected.channel, tint: tint,
                                     onWatchLive: { context in
                                         // Close this sheet before the player is asked for. The
                                         // player is a fullScreenCover on the tab view and cannot
                                         // present while anything else is up; the launcher polls
                                         // two seconds and then gives up silently, which reads as
                                         // a dead button.
                                         channelSelection = nil
                                         onWatchLive?(context)
                                     })
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.channels.isEmpty, model.isLoading, model.loadError == nil, searchText.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.channels.isEmpty, let error = model.loadError {
            ContentUnavailableView {
                Label("livetv.loadFailed.title", systemImage: "tv.slash")
            } description: {
                Text(error)
            } actions: {
                Button("home.retry") { Task { await model.recover() } }
            }
        } else {
            List {
                Section {
                    // Inline field, not .searchable: the Live TV tab is not inside a
                    // NavigationStack, and .searchable silently renders nothing without one.
                    searchField
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                    filterChips
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
                if model.channels.isEmpty {
                    ContentUnavailableView("livetv.guide.empty.filtered",
                                           systemImage: "line.3.horizontal.decrease.circle")
                        .listRowBackground(Color.clear)
                }
                ForEach(model.channels) { channel in
                    ChannelRow(channel: channel,
                               schedule: model.schedule(for: channel),
                               isFavorite: model.timers.isFavorite(channel.id),
                               tint: tint,
                               onPlay: {
                                   // LivePlaybackContext.program is optional, so a channel without
                                   // EPG data launches without program metadata rather than with a
                                   // fabricated one.
                                   onWatchLive?(LivePlaybackContext(
                                       channel: channel,
                                       program: model.currentProgram(for: channel)))
                               })
                        .contentShape(Rectangle())
                        .onTapGesture { channelSelection = ChannelSelection(channel: channel) }
                        .task { await model.ensurePrograms(for: [channel.id]) }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("livetv.guide.search.placeholder", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.Theme.surfaceElevated))
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                phoneChip(Text("livetv.guide.filter.favorites"),
                          isOn: model.filter.favoritesOnly) {
                    var next = model.filter
                    next.favoritesOnly.toggle()
                    Task { await model.apply(filter: next) }
                }
                ForEach(GuideFilter.Category.allCases) { category in
                    phoneChip(Text(category.titleKey), isOn: model.filter.category == category) {
                        var next = model.filter
                        next.category = next.category == category ? nil : category
                        Task { await model.apply(filter: next) }
                    }
                }
                if model.hasRadioChannels {
                    phoneChip(Text("livetv.guide.filter.radio"), isOn: model.filter.kind == .radio) {
                        var next = model.filter
                        next.kind = next.kind == .radio ? .tv : .radio
                        Task { await model.apply(filter: next) }
                    }
                }
            }
        }
    }

    private func phoneChip(_ title: Text,
                           isOn: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(isOn ? tint.opacity(0.25) : Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(isOn ? tint : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Logo, identity, what is on now with its progress, what follows, and a direct play button.
private struct ChannelRow: View {
    let channel: JellyfinChannel
    /// The channel's loaded schedule. The row derives "now" and "next" from it on a minute clock
    /// rather than being handed two values computed once: a program boundary passes without anything
    /// else in the model changing, so nothing would otherwise invalidate those two lines (#96).
    let schedule: [JellyfinProgram]
    let isFavorite: Bool
    let tint: Color
    let onPlay: () -> Void

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(spacing: 12) {
            AsyncCachedImage(url: logoURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "tv").foregroundStyle(.tertiary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name).font(.headline).lineLimit(1)
                    if let number = channel.channelNumber {
                        Text(number).font(.caption).foregroundStyle(.secondary)
                    }
                    if isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let current = ChannelListViewModel.currentProgram(
                        at: context.date, in: schedule, fallback: channel.currentProgram)
                    let next = ChannelListViewModel.nextProgram(after: context.date, in: schedule)
                    VStack(alignment: .leading, spacing: 3) {
                        if let current {
                            Text("livetv.channelList.now \(current.name)")
                                .font(.subheadline)
                                .lineLimit(1)
                            ChannelRowProgress(program: current, now: context.date, tint: tint)
                        }
                        if let next, let start = next.startDate {
                            Text("livetv.channelList.next \(next.name) \(DateFormatter.guideShortTime.string(from: start))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var logoURL: URL? {
        dependencies.jellyfinImageService.imageURL(
            itemID: channel.id, serverID: channel.serverID, imageType: .primary,
            tag: channel.primaryImageTag, maxHeight: 120)
    }
}

/// Drawn from the row's clock rather than one of its own: the bar and the two lines above it are
/// the same statement about the same moment, and two clocks could disagree for a frame.
private struct ChannelRowProgress: View {
    let program: JellyfinProgram
    let now: Date
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * fraction(at: now))
            }
        }
        .frame(height: 3)
    }

    private func fraction(at now: Date) -> CGFloat {
        guard let start = program.startDate, let end = program.endDate else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / total)))
    }
}

/// The channel's full schedule with a day switcher. Tapping a program opens the same action sheet
/// the grid uses, so record behaviour is identical on both platforms.
private struct ChannelScheduleSheet: View {
    let model: ChannelListViewModel
    let channel: JellyfinChannel
    let tint: Color
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Day offset, not a Date: two `Date()` values created a moment apart are not equal, so a
    /// Date-tagged Picker would open with nothing selected.
    @State private var dayOffset = 0
    @State private var selection: ChannelProgramSelection?

    private var day: Date {
        let days = model.scheduleDays
        return dayOffset < days.count ? days[dayOffset] : Date()
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("livetv.channelList.day", selection: $dayOffset) {
                    ForEach(Array(model.scheduleDays.enumerated()), id: \.offset) { offset, date in
                        Text(date.formatted(date: .abbreviated, time: .omitted)).tag(offset)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                ForEach(model.schedule(for: channel, on: day)) { program in
                    Button {
                        selection = ChannelProgramSelection(channel: channel, program: program)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(program.startDate.map { DateFormatter.guideShortTime.string(from: $0) } ?? "")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(program.name).font(.body)
                                if program.isAiring(at: Date()) {
                                    Text("livetv.channelList.airing")
                                        .font(.caption)
                                        .foregroundStyle(tint)
                                }
                            }
                            Spacer(minLength: 0)
                            if model.timers.hasTimer(programID: program.id) {
                                Image(systemName: "record.circle").foregroundStyle(Color.Theme.recording)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .task { await model.ensurePrograms(for: [channel.id]) }
            .sheet(item: $selection) { selected in
                ProgramInfoPopover(
                    program: selected.program, channel: selected.channel, tint: tint,
                    onWatchLive: { context in
                        // Two sheets deep: the popover dismisses itself, this dismisses the
                        // schedule sheet, and ChannelListView clears the item binding. All three
                        // are needed before the player can present.
                        dismiss()
                        onWatchLive?(context)
                    },
                    channelIsFavorite: model.timers.isFavorite(selected.channel.id),
                    onToggleFavorite: { model.timers.toggleFavorite(channelID: selected.channel.id) },
                    hasTimer: model.timers.effectiveTimerState(for: selected.program).timerId != nil,
                    hasSeriesTimer: model.timers.effectiveTimerState(for: selected.program).seriesTimerId != nil,
                    onToggleRecord: { model.timers.toggleRecord(program: selected.program) },
                    onToggleSeriesRecord: { model.timers.toggleSeriesRecord(program: selected.program) })
            }
        }
    }
}
