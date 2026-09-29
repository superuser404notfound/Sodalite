import SwiftUI

/// Bundles channel and program so the action cover receives both atomically. With two separate
/// `@State`s the cover presents as soon as the program is set and the channel reads nil on the
/// first open, leaving the sheet empty.
private struct GuideSelection: Identifiable {
    let channel: JellyfinChannel
    let program: JellyfinProgram
    var id: String { "\(channel.id)-\(program.id)" }
}

/// Hero, controls and the UIKit canvas, plus the loading, error and empty states.
struct GuideView: View {
    @State private var model: GuideViewModel
    let tint: Color
    var onWatchLive: ((LivePlaybackContext) -> Void)?
    var isActive: Bool = true
    /// Bumped by the tab when the live player closes, arming the one-shot correction of where the
    /// restored focus lands. See `GuideGridViewController.correctRestoreLanding`.
    var focusRequest: Int = 0
    /// Set while the player runs and briefly after, so the chips do not compete for the restored
    /// focus with the grid.
    var chromeFocusSuppressed: Bool = false
    /// Called when the grid takes focus, so the tab can un-suppress the chrome immediately.
    var onGridFocused: () -> Void = {}

    @State private var selection: GuideSelection?

    init(model: GuideViewModel,
         tint: Color,
         onWatchLive: ((LivePlaybackContext) -> Void)? = nil,
         isActive: Bool = true,
         focusRequest: Int = 0,
         chromeFocusSuppressed: Bool = false,
         onGridFocused: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.tint = tint
        self.onWatchLive = onWatchLive
        self.isActive = isActive
        self.focusRequest = focusRequest
        self.chromeFocusSuppressed = chromeFocusSuppressed
        self.onGridFocused = onGridFocused
    }

    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading

    private func watchLive(_ context: LivePlaybackContext) {
        var stamped = context
        stamped.zapFilter = model.filter.zapLineup
        onWatchLive?(stamped)
    }

    var body: some View {
        content
            .task { await model.load() }
            // Full-screen cover, not a sheet: a tvOS sheet leaves the tab bar visible behind it and
            // tvOS 26 re-templates the backgrounded bar gray. The cover covers the bar instead.
            .detailCover(item: $selection) { selected in
                ProgramInfoPopover(
                    program: selected.program, channel: selected.channel, tint: tint,
                    onWatchLive: onWatchLive == nil ? nil : { watchLive($0) },
                    channelIsFavorite: model.timers.isFavorite(selected.channel.id),
                    onToggleFavorite: { model.timers.toggleFavorite(channelID: selected.channel.id) },
                    hasTimer: model.timers.effectiveTimerState(for: selected.program).timerId != nil,
                    hasSeriesTimer: model.timers.effectiveTimerState(for: selected.program).seriesTimerId != nil,
                    onToggleRecord: { model.timers.toggleRecord(program: selected.program) },
                    onToggleSeriesRecord: { model.timers.toggleSeriesRecord(program: selected.program) })
                // Attached INSIDE the cover: SwiftUI will not present an alert and a cover from the
                // same node at once, so a fast record-toggle failure was dropped while the cover
                // stayed up with its optimistically flipped button.
                .alert(
                    Text("livetv.recording.error.title"),
                    isPresented: Binding(
                        get: { model.timers.recordingError != nil },
                        set: { if !$0 { model.timers.recordingError = nil } })
                ) {
                    Button("common.ok", role: .cancel) {}
                } message: {
                    Text(model.timers.recordingError ?? "")
                }
            }
            // Gated on `selection == nil`: while the cover is up its own alert owns presentation,
            // and without the gate both observe the same error and one becomes undismissable.
            .alert(
                Text("livetv.recording.error.title"),
                isPresented: Binding(
                    get: { selection == nil && model.timers.recordingError != nil },
                    set: { if !$0 { model.timers.recordingError = nil } })
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(model.timers.recordingError ?? "")
            }
    }

    /// Hero and controls render in every state that has a channel list at all, so the chrome does
    /// not jump when a filter empties the grid: only the canvas area swaps.
    @ViewBuilder
    private var content: some View {
        if model.channels.isEmpty, let error = model.loadError {
            ContentUnavailableView {
                Label("livetv.loadFailed.title", systemImage: "tv.slash")
            } description: {
                Text(error)
            } actions: {
                Button("home.retry") { Task { await model.recover() } }
            }
        } else {
            VStack(spacing: 0) {
                GuideHeroView(program: model.heroProgram, channel: model.heroChannel,
                              metrics: model.metrics, tint: tint)
                GuideControlsView(model: model, metrics: model.metrics, tint: tint,
                                  isFocusable: !chromeFocusSuppressed)
                canvas
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if model.channels.isEmpty {
            if model.channelsComplete {
                // A filter or a search that matched nothing, not a failure. Naming the cause beats
                // an empty grid that reads as a broken server, and the chips stay reachable above.
                ContentUnavailableView("livetv.guide.empty.filtered",
                                       systemImage: "line.3.horizontal.decrease.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Still fetching. isLoadingChannels is not the test: it stays false while the
                // guide-info and radio probes run ahead of the first channel page.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GuideGridContainer(
                model: model,
                tint: tint,
                isActive: isActive,
                focusRequest: focusRequest,
                onSelect: { channel, program in
                    selection = GuideSelection(channel: channel, program: program)
                },
                onPlayChannel: { channel, program in
                    // LivePlaybackContext.program is optional: a channel with no EPG data simply
                    // launches without program metadata.
                    watchLive(LivePlaybackContext(channel: channel, program: program))
                },
                onToggleFavorite: { channel in
                    model.timers.toggleFavorite(channelID: channel.id)
                },
                onGridFocused: onGridFocused)
            // Keep the top safe area so the grid starts below the tab bar.
            .ignoresSafeArea(edges: [.horizontal, .bottom])
            // The grid draws to its container's edge, and beside a sidebar that edge is the rail.
            // Outside the safe-area opt-out, so it survives it (Sodalite#140).
            .padding(.leading, shellPaysLeading ? SidebarMetrics.contentLeading : 0)
        }
    }
}
