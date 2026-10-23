import SwiftUI

/// The Mac's `PlayerLauncher`: same name, same parameters, same invisible-overlay call shape as the
/// UIKit one every detail screen already holds, so no caller has to know which platform it is on.
///
/// It presents from SwiftUI rather than from a view controller because none of the reasons the
/// other platforms present a modal `UIViewController` survive on a Mac: there is no Menu button to
/// intercept, no focus engine to keep out of, and no scene modal chain to settle. The player gets a
/// window of its own (see `MacPlayerWindowSession`), the way a Mac media app plays video: it can
/// be resized, moved to another display or made full screen without taking the library with it.
struct PlayerLauncher: View {
    @Binding var isPresented: Bool
    let item: JellyfinItem?
    let startFromBeginning: Bool
    let playbackService: JellyfinPlaybackServiceProtocol
    var itemService: JellyfinItemServiceProtocol?
    let userID: String
    let preferences: PlaybackPreferences
    var trackMemory: TrackSelectionMemory?
    var spoilerPolicy: SpoilerPolicy = .disabled
    var cachedPlaybackInfo: PrefetchedPlaybackInfo?
    var preferredMediaSourceID: String?
    var playQueue: [JellyfinItem] = []
    var localDownload: DownloadedItem?
    var downloadStore: DownloadStore?

    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.appState) private var appState
    @Environment(\.serverSession) private var serverSession

    /// Built once per launch and held for the life of the session. A rebuilt view model re-requests
    /// PlaybackInfo, which is the churn `PlayerLauncherHostVC` latches against on the other
    /// platforms; here the state is the latch.
    @State private var session: PlayerViewModel?

    private var serverName: String { serverSession?.server?.name ?? appState.activeServer?.name ?? "" }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .modifier(MacPlayerWindowPresenter(session: $session, theme: appearanceTheme) {
                isPresented = false
            })
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented, session == nil, let item {
                    session = makeViewModel(for: item)
                } else if !presented {
                    session = nil
                }
            }
            // A deep link tears the player down before it resolves the item it is opening.
            .onChange(of: appState.requestPlayerDismissal) { _, _ in
                isPresented = false
            }
    }

    private func makeViewModel(for item: JellyfinItem) -> PlayerViewModel {
        let state = appState
        return PlayerViewModel(
            item: item,
            startFromBeginning: startFromBeginning,
            playbackService: playbackService,
            userID: userID,
            preferences: preferences,
            itemService: itemService,
            trackMemory: trackMemory,
            spoilerPolicy: spoilerPolicy,
            canTranscodeVideo: state.canTranscodeVideo(on: serverSession),
            cachedPlaybackInfo: cachedPlaybackInfo,
            preferredMediaSourceID: preferredMediaSourceID,
            playQueue: playQueue,
            serverName: serverName,
            // Handed over as a reader, not a value: a server that dies forty minutes in is exactly
            // the case the player needs it for.
            serverReachability: { state.serverReachability },
            localDownload: localDownload,
            downloadStore: downloadStore
        )
    }
}

extension PlayerViewModel: @MainActor Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
