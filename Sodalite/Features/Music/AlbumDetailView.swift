import SwiftUI

// MARK: - View Model

@Observable @MainActor final class AlbumDetailViewModel {
    private(set) var songs: [JellyfinItem] = []
    private(set) var isLoading = false
    /// Same rule as the album grid (Sodalite#88): a failed fetch is not an album without tracks.
    /// Swallowed, it rendered a cover and a Play button over an empty list with nothing said.
    private(set) var errorMessage: String?
    /// A load that actually answered, which is what separates "this album has no tracks" from "we
    /// have not asked yet". Only the former may recenter the header.
    private(set) var hasResolved = false

    var displayedError: String? { songs.isEmpty ? errorMessage : nil }

    /// A load that answered with no tracks and nothing to say about why, which is the one state in
    /// which the tracklist renders nothing at all. An in-flight load and the frame before the first
    /// one starts are deliberately not this, or an album that does have tracks would start centered
    /// and jump into place.
    var isConfirmedEmpty: Bool {
        hasResolved && !isLoading && songs.isEmpty && displayedError == nil
    }

    /// Play and Shuffle hand `songs` to the coordinator, which refuses an empty queue outright, so
    /// without tracks they are controls that cannot do anything. That covers the album that has
    /// none and the fetch that failed alike.
    var canPlay: Bool { !songs.isEmpty }

    /// The album's own server answers, in a combined setup too (Sodalite#85).
    func load(album: JellyfinItem, using dependencies: DependencyContainer) async {
        let route = dependencies.musicRoute(for: album)
        await load(albumID: album.id, service: route.service, userID: route.userID, serverID: album.serverID)
    }

    func load(albumID: String, service: JellyfinMusicServiceProtocol, userID: String?, serverID: String? = nil) async {
        guard let userID else {
            LogTap.shared.note("[music] songs: no active user, nothing requested")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = MusicHomeViewModel.stamped(
                try await service.getSongs(userID: userID, albumID: albumID), serverID: serverID)
            songs = fetched
            errorMessage = nil
            hasResolved = true
            LogTap.shared.note("[music] songs: \(fetched.count) returned for album \(albumID)")
        } catch is CancellationError {
            // A cancelled reload is not an outcome. The next one answers.
        } catch {
            errorMessage = ErrorText.user(for: error)
            hasResolved = true
            LogTap.shared.note("[music] songs failed for album \(albumID): \(HTTPDiagnostics.describe(error))")
        }
    }
}

// MARK: - View

struct AlbumDetailView: View {
    let album: JellyfinItem

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var viewModel = AlbumDetailViewModel()

    var body: some View {
        let metrics = LayoutMetrics.current(hSizeClass)
        ScrollView {
            VStack(alignment: .leading, spacing: hSizeClass == .compact ? 28 : 40) {
                albumHeader
                tracklist
            }
            .padding(.horizontal, metrics.gridInset)
            .padding(.vertical, hSizeClass == .compact ? 24 : 40)
        }
        // Hide the top tab bar inside an album, matching movie/series/catalog detail (playlists via
        // DetailRouterView already hide it; this covers the music tab's album destination).
        .hidesShellTabBar()
        .task {
            await viewModel.load(album: album, using: dependencies)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var albumHeader: some View {
        if hSizeClass == .compact {
            // Stack vertically so the title and Play button are never clipped on a phone width.
            VStack(alignment: .leading, spacing: 20) {
                coverImage
                    .frame(maxWidth: .infinity, alignment: .center)
                titleBlock(alignment: .leading)
                headerActions
            }
        } else {
            let alone = viewModel.isConfirmedEmpty
            // AnyLayout rather than an if/else: the children keep their identity across the switch,
            // so the move animates and a focused Play button stays focused. Two branches rebuild them.
            let layout = alone
                ? AnyLayout(VStackLayout(alignment: .center, spacing: 24))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 48))

            layout {
                coverImage

                VStack(alignment: alone ? .center : .leading, spacing: 16) {
                    titleBlock(alignment: alone ? .center : .leading)
                    headerActions
                }
                .frame(maxWidth: .infinity, alignment: alone ? .center : .leading)
            }
            .animation(.easeInOut(duration: 0.25), value: alone)
        }
    }

    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(album.name)
                .font(.title2)
                .fontWeight(.bold)

            if let artist = album.albumArtist, !artist.isEmpty {
                Text(artist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let year = album.productionYear {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    @ViewBuilder
    private var headerActions: some View {
        if viewModel.isLoading {
            ProgressView()
                .padding(.top, 8)
        } else if viewModel.canPlay {
            actionButtons
        } else if viewModel.isConfirmedEmpty {
            // In the header, not below it, so the centered column stays the whole page. A line under
            // the header would put content back beside the cover and strand it again.
            Text("album.detail.empty")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var coverSide: CGFloat { hSizeClass == .compact ? 220 : 340 }

    private var coverImage: some View {
        AsyncCachedImage(url: dependencies.jellyfinImageService.posterURL(for: album, maxWidth: ImageWidth.cover)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.Theme.restFill)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                )
        }
        .frame(width: coverSide, height: coverSide)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            GlassActionButton(
                title: "album.detail.play",
                systemImage: "play.fill",
                isProminent: true
            ) {
                dependencies.musicPlaybackCoordinator.play(
                    queue: viewModel.songs,
                    startAt: 0,
                    contextTitle: album.name
                )
            }

            GlassActionButton(
                title: "album.detail.shuffle",
                systemImage: "shuffle"
            ) {
                dependencies.musicPlaybackCoordinator.play(
                    queue: viewModel.songs.shuffled(),
                    startAt: 0,
                    contextTitle: album.name
                )
            }
        }
        .collapsesActionButtonLabel()
    }

    // MARK: Tracklist

    @ViewBuilder
    private var tracklist: some View {
        if let error = viewModel.displayedError, !viewModel.isLoading {
            VStack(alignment: .leading, spacing: 12) {
                Text(error)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await viewModel.load(album: album, using: dependencies) }
                } label: {
                    Text("home.retry")
                        .font(.body)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
        } else if !viewModel.isLoading && !viewModel.songs.isEmpty {
            let coordinator = dependencies.musicPlaybackCoordinator
            VStack(spacing: 8) {
                ForEach(Array(viewModel.songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(
                        song: song,
                        number: song.indexNumber,
                        isCurrent: coordinator.currentItem?.id == song.id,
                        isPlaying: coordinator.isPlaying,
                        onSelect: {
                            // Tapping the already-playing track just opens the player; don't restart it.
                            if coordinator.currentItem?.id == song.id {
                                coordinator.requestNowPlayingPresentation()
                            } else {
                                coordinator.play(queue: viewModel.songs, startAt: index, contextTitle: album.name)
                            }
                        }
                    )
                }
            }
        }
    }
}
