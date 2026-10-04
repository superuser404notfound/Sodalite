import SwiftUI

struct LiveTVTabView: View {
    /// Whether this tab is the selected one. See TabRootView's call site.
    let isTabSelected: Bool
    /// Participants with Live TV, active first (Sodalite#85).
    let capableServerIDs: [String]

    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // Late-bound once the active user is known, then stable across re-renders (matches MusicHomeView);
    // an inline expression would hand State a fresh throwaway vm each render.
    @State private var guideModel: GuideViewModel?
    @State private var channelListModel: ChannelListViewModel?
    @State private var timers: LiveTimerStore?
    @State private var recordingsModel: RecordingsViewModel?
    @State private var programsModel: LiveProgramsViewModel?
    @State private var liveContext: LivePlaybackContext?
    @State private var isPlayerPresented = false
    @State private var section: LiveTVSection = .overview
    /// Bumped when the player closes. The guide grid uses it to pull focus back off the segment
    /// picker and onto the channel that was being watched.
    @State private var guideFocusRequest = 0
    /// Names the content area as this tab's default focus target. Measured on the device: when the
    /// live player closes, focus is restored from the SwiftUI side onto the segment picker, and a
    /// UIKit-side UIFocusSystem.requestFocusUpdate into the grid is denied from there. So the
    /// preference has to be declared where the restore actually looks.
    /// Takes the segment picker and the filter chips out of the focus engine while the player covers
    /// the screen and for a moment after it closes.
    ///
    /// Measured on the device: on tvOS 26 SwiftUI owns focus. After the player is dismissed it puts
    /// focus on the segment picker, and a UIKit UIFocusSystem.requestFocusUpdate into the grid is
    /// refused for as long as it holds it, with the target cell present and focusable, no ancestor
    /// out of the focus engine, and every controller reporting restoresFocusAfterTransition. Focus
    /// cannot be taken here, only given, so the chrome stops offering itself for that moment and the
    /// grid is what is left. Its remembered index path then does the rest.
    @State private var chromeFocusSuppressed = false
    @State private var chromeFocusRelease: Task<Void, Never>?
    /// Last requestContentReload this view answered (same latch as TabRootView's).
    @State private var lastHandledContentReload = 0
    /// The server the models below were built for (Sodalite#85).
    @State private var builtForServerID: String?
    @State private var builtForKey: String?
    @State private var rememberedServerID: String?
    @State private var isServerPickerPresented = false

    private enum LiveTVSection { case overview, guide, recordings }

    /// Hand the chrome back as soon as the grid has focus, so the picker is only ever disabled for
    /// the handful of frames the restore needs.
    private func releaseChromeFocus() {
        guard chromeFocusSuppressed else { return }
        chromeFocusRelease?.cancel()
        chromeFocusSuppressed = false
    }

    private var tint: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter)
    }

    private var sources: [LiveTVSource] {
        dependencies.activeUserID.map { dependencies.liveTVSources(activeUserID: $0) } ?? []
    }

    private var chosenServerID: String? {
        LiveTVServerChoice.resolve(capable: capableServerIDs, remembered: rememberedServerID)
    }

    /// Before the first probe lands this is the active server, exactly as before Sodalite#85.
    private var source: LiveTVSource? {
        let all = sources
        return all.first { $0.serverID == chosenServerID } ?? all.first { $0.isActive }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.top, 20)
            ZStack {
                Group {
                    #if os(iOS)
                    // Compact gets the channel list: a 2D grid behind a channel column does not fit
                    // a phone, and shrinking it further does not fix that.
                    if hSizeClass == .compact, let channelListModel {
                        ChannelListView(model: channelListModel, tint: tint,
                                        onWatchLive: { context in
                                            liveContext = context
                                            isPlayerPresented = true
                                        })
                    } else if let guideModel {
                        GuideView(
                            model: guideModel,
                            tint: tint,
                            onWatchLive: { context in
                                liveContext = context
                                // Launcher polls for the info sheet to finish dismissing before
                                // presenting the player, so flipping this immediately is safe.
                                isPlayerPresented = true
                            },
                            isActive: section == .guide,
                            focusRequest: guideFocusRequest,
                            chromeFocusSuppressed: chromeFocusSuppressed,
                            onGridFocused: releaseChromeFocus
                        )
                    } else {
                        ProgressView()
                    }
                    #else
                    if let guideModel {
                        GuideView(
                            model: guideModel,
                            tint: tint,
                            onWatchLive: { context in
                                liveContext = context
                                isPlayerPresented = true
                            },
                            isActive: section == .guide,
                            focusRequest: guideFocusRequest,
                            chromeFocusSuppressed: chromeFocusSuppressed,
                            onGridFocused: releaseChromeFocus
                        )
                    } else {
                        ProgressView()
                    }
                    #endif
                }
                // A new server gets a fresh grid; the old one's scroll and focus belong to other channels.
                .id(builtForServerID)
                // Keep the UIKit grid alive across the toggle (scroll + focus state survive); just hide it.
                .opacity(section == .guide ? 1 : 0)
                .allowsHitTesting(section == .guide)

                if section == .overview, let programsModel, let guideModel, let timers {
                    LiveProgramsView(
                        model: programsModel,
                        timers: timers,
                        guideChannels: guideModel.channels,
                        tint: tint,
                        isPlayerPresented: isPlayerPresented,
                        isTabSelected: isTabSelected,
                        onWatchLive: { context in
                            liveContext = context
                            isPlayerPresented = true
                        })
                }

                if section == .recordings, let recordingsModel {
                    RecordingsView(model: recordingsModel, tint: tint)
                        .environment(\.serverSession, builtForServerID.flatMap {
                            dependencies.sessionRegistry.session(forServerID: $0)
                        })
                }
            }
        }
        .onAppear { rememberedServerID = dependencies.rememberedLiveTVServerID() }
        .task(id: source.map { "\($0.serverID)|\($0.userID)" }) {
            guard let source else { return }
            let key = "\(source.serverID)|\(source.userID)"
            guard key != builtForKey else { return }
            builtForKey = key
            builtForServerID = source.serverID
            let store = LiveTimerStore(service: source.liveTvService, userID: source.userID)
            timers = store
            guideModel = GuideViewModel(service: source.liveTvService, userID: source.userID, timers: store)
            channelListModel = ChannelListViewModel(
                service: source.liveTvService, userID: source.userID, timers: store)
            recordingsModel = RecordingsViewModel(
                liveTvService: source.liveTvService, itemService: source.itemService, userID: source.userID)
            programsModel = LiveProgramsViewModel(service: source.liveTvService, userID: source.userID)
        }
        // The server is back within a running session (Sodalite#122): a guide whose load failed while it
        // was away retries, and the Overview rows are asked again.
        .task(id: appState.requestContentReload) {
            let signal = appState.requestContentReload
            guard signal > 0, signal != lastHandledContentReload else { return }
            lastHandledContentReload = signal
            await guideModel?.recover()
            await channelListModel?.recover()
            await programsModel?.refresh()
        }
        .onChange(of: isPlayerPresented) { wasPresented, isPresented in
            chromeFocusRelease?.cancel()
            if isPresented {
                chromeFocusSuppressed = true
                return
            }
            // Closing the player, not opening it. SwiftUI restores focus to the segment picker at
            // that point, which is not where the user left it.
            guard wasPresented, section == .guide else {
                chromeFocusSuppressed = false
                return
            }
            guideFocusRequest += 1
            // Normally released the moment the grid reports focus. This is only the backstop for the
            // case where it never does, so the chrome cannot stay disabled.
            chromeFocusRelease = Task {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                chromeFocusSuppressed = false
            }
        }
        .onChange(of: section) { _, newValue in
            // Recordings can cancel timers/rules the overlay doesn't know; resync on the way back so
            // dots/actions match the server. Übersicht shares the model (and is the default landing), so resync it too.
            // The Overview rows carry snapshots of their own, often for channels the guide never loaded.
            guard newValue == .guide || newValue == .overview,
                  let guideModel, let timers else { return }
            let overviewPrograms = programsModel?.rows.values.flatMap { $0 } ?? []
            Task { await timers.syncWithServer(knownPrograms: guideModel.allLoadedPrograms + overviewPrograms) }
        }
        .overlay {
            // Guard userID at the call site (mirrors MovieDetailView) so the live player never launches blank.
            if let source {
                LivePlayerLauncher(
                    isPresented: $isPlayerPresented,
                    context: isPlayerPresented ? liveContext : nil,
                    playbackService: source.playbackService,
                    liveTvService: source.liveTvService,
                    userID: source.userID,
                    serverName: source.serverName,
                    preferences: dependencies.playbackPreferences,
                    directStreamMemory: dependencies.liveDirectStreamMemory
                )
                .allowsHitTesting(false)
            }
        }
    }

    /// Native segmented control, matching the Catalog tab's bar for consistency. It replaced custom
    /// pills that existed because a segmented control was suspected of fighting the EPG's custom focus
    /// handling; if focus between this picker and the UIKit grid misbehaves, revert this commit
    /// (pill implementation lives in its parent) instead of patching around it.
    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Text("livetv.segment.overview").tag(LiveTVSection.overview)
            Text("livetv.segment.guide").tag(LiveTVSection.guide)
            Text("livetv.segment.recordings").tag(LiveTVSection.recordings)
        }
        .pickerStyle(.segmented)
        // Disabled, not .focusable(false): the latter makes SwiftUI treat the segmented control as a
        // single focus item and its own left/right segment selection dies with it, at any value.
        // Only while the player covers the screen and for a moment after it closes, see
        // chromeFocusSuppressed.
        .disabled(chromeFocusSuppressed)
    }

    private var headerRow: some View {
        HStack(spacing: hSizeClass == .compact ? 12 : 24) {
            sectionPicker
            if LiveTVSwitcher.isVisible(capable: capableServerIDs), let source {
                LiveServerChip(name: source.serverName, tint: tint,
                               isFocusable: !chromeFocusSuppressed) {
                    guard !isPlayerPresented else { return }
                    isServerPickerPresented = true
                }
            }
        }
        // tvOS/iPad keep the wide inset; compact uses a phone-scale margin so the control fits ~393pt.
        .padding(.horizontal, hSizeClass == .compact ? 16 : 80)
        .menuPresentation(isPresented: $isServerPickerPresented) {
            CatalogPickerSheet(
                title: String(localized: "multiServer.picker.header.label"),
                options: LiveTVSwitcher.options(capable: capableServerIDs, sources: sources),
                selectedID: chosenServerID,
                onSelect: { serverID in
                    dependencies.rememberLiveTVServer(serverID)
                    rememberedServerID = serverID
                    isServerPickerPresented = false
                },
                onCancel: { isServerPickerPresented = false })
        }
    }
}

/// The Live TV server switcher (Sodalite#85), shaped like the guide's filter chips.
private struct LiveServerChip: View {
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
            .focusable(isFocusable)
            .focused($focused)
            .stableTap(isFocused: focused) { action() }
            .fixedSize()
    }
}
