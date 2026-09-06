import SwiftUI

struct LiveTVTabView: View {
    /// Whether this tab is the selected one. See TabRootView's call site.
    let isTabSelected: Bool

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

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
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
                }
            }
        }
        .task {
            guard guideModel == nil, let userID = dependencies.activeUserID else { return }
            let store = LiveTimerStore(service: dependencies.jellyfinLiveTvService, userID: userID)
            timers = store
            guideModel = GuideViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID, timers: store)
            channelListModel = ChannelListViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID, timers: store)
            recordingsModel = RecordingsViewModel(
                liveTvService: dependencies.jellyfinLiveTvService,
                itemService: dependencies.jellyfinItemService,
                userID: userID)
            programsModel = LiveProgramsViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID)
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
            guard newValue == .guide || newValue == .overview,
                  let guideModel, let timers else { return }
            Task { await timers.syncWithServer(knownPrograms: guideModel.allLoadedPrograms) }
        }
        .overlay {
            // Guard userID at the call site (mirrors MovieDetailView) so the live player never launches blank.
            if let userID = dependencies.activeUserID {
                LivePlayerLauncher(
                    isPresented: $isPlayerPresented,
                    context: isPlayerPresented ? liveContext : nil,
                    playbackService: dependencies.jellyfinPlaybackService,
                    liveTvService: dependencies.jellyfinLiveTvService,
                    userID: userID,
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
        // tvOS/iPad keep the wide inset; compact uses a phone-scale margin so the control fits ~393pt.
        .padding(.horizontal, hSizeClass == .compact ? 16 : 80)
    }
}
