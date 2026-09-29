#if os(iOS)
import SwiftUI

/// A reduced detail page built from the snapshot, for a download opened with no server (Sodalite#81).
struct OfflineDetailView: View {
    let item: DownloadedItem
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState
    @State private var showPlayer = false

    var body: some View {
        let snapshot = item.snapshot.item
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LocalArtwork(url: item.artworkURL(.backdrop) ?? item.artworkURL(.thumb))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let seriesName = snapshot.seriesName {
                    Text(seriesName).font(.headline).foregroundStyle(.secondary)
                }
                Text(snapshot.name).font(.title2).fontWeight(.bold)
                if let ticks = snapshot.runTimeTicks {
                    Text(Duration.seconds(Double(ticks) / 10_000_000)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                GlassActionButton(title: "detail.play", systemImage: "play.fill", isProminent: true) {
                    showPlayer = true
                }
                .disabled(dependencies.downloadStore.completedItem(item.id) == nil)
                if let overview = snapshot.overview {
                    Text(overview).font(.body)
                }
            }
            .padding()
        }
        .navigationTitle(snapshot.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let userID = appState.activeUser?.id ?? appState.profileKey?.userID {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? snapshot : nil,
                    startFromBeginning: false,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    localDownload: dependencies.downloadStore.completedItem(item.id),
                    downloadStore: dependencies.downloadStore
                )
                .allowsHitTesting(false)
            }
        }
    }
}
#endif
