import SwiftUI

@Observable @MainActor final class MusicHomeViewModel {
    private(set) var albums: [JellyfinItem] = []
    /// The album grid's fallback list, filled only when the server holds no albums at all.
    private(set) var songs: [JellyfinItem] = []
    private(set) var isLoading = false
    /// Set only when the fetch threw. `try? ... ?? []` used to collapse every failure into an empty
    /// array, so a 400, a decode mismatch and a genuinely empty music library all rendered the same
    /// "No albums found" screen and left nothing in the diagnostic log either (Sodalite#88). Empty
    /// and failed are not the same state, the rule Home already follows for its rows.
    private(set) var errorMessage: String?

    /// The error screen is for a viewer with nothing else to look at. A reload that fails while a
    /// grid is already up keeps the grid, so a transient hiccup does not empty the tab. The fallback
    /// track list counts as content for the same reason.
    var displayedError: String? { albums.isEmpty && songs.isEmpty ? errorMessage : nil }

    /// A page of tracks, not a paginated list. High enough that an album-less library arrives whole
    /// in practice, low enough that a 40k-track server does not build a view nobody can scroll; the
    /// service says in the log when it had to cut.
    static let songLimit = 500

    func load(using dependencies: DependencyContainer) async {
        await load(service: dependencies.jellyfinMusicService, userID: dependencies.activeUserID)
    }

    func load(service: JellyfinMusicServiceProtocol, userID: String?) async {
        guard let userID else {
            LogTap.shared.note("[music] albums: no active user, nothing requested")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await service.getAlbums(userID: userID)
            albums = fetched
            errorMessage = nil
            LogTap.shared.note("[music] albums: \(fetched.count) returned")
            if fetched.isEmpty {
                await loadSongs(service: service, userID: userID)
            } else {
                songs = []
            }
        } catch is CancellationError {
            // A cancelled reload is not an outcome. The next one answers.
        } catch {
            errorMessage = ErrorText.user(for: error)
            LogTap.shared.note("[music] albums failed: \(HTTPDiagnostics.describe(error))")
        }
    }

    /// Jellyfin builds `MusicAlbum` from folder boundaries, not from the tracks' `Album` tag, so a
    /// library whose files sit in one flat folder answers the album query with nothing while its
    /// tracks are right there, and every route into music in this app went through an album
    /// (Sodalite#88). Zero albums is the only state that asks this question.
    ///
    /// A failure here does not become the tab's verdict: the server already answered the first
    /// question, and "no albums" stays what it said.
    private func loadSongs(service: JellyfinMusicServiceProtocol, userID: String) async {
        do {
            songs = try await service.getAllSongs(userID: userID, limit: Self.songLimit)
        } catch is CancellationError {
            // A cancelled reload is not an outcome. The next one answers.
        } catch {
            LogTap.shared.note("[music] all songs failed: \(HTTPDiagnostics.describe(error))")
        }
    }
}

struct MusicHomeView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var viewModel = MusicHomeViewModel()
    @State private var selectedAlbum: JellyfinItem?
    @FocusState private var focusedAlbumID: String?

    var body: some View {
        let metrics = LayoutMetrics.current(hSizeClass)
        ThemeNavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if dependencies.musicPlaybackCoordinator.currentItem != nil {
                        NowPlayingCard()
                            .padding(.horizontal, metrics.gridInset)
                            .padding(.top, hSizeClass == .compact ? 16 : 40)
                            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                                       value: dependencies.musicPlaybackCoordinator.currentItem?.id)
                    }
                    gridContent
                }
            }
            .scrollsUnderShellChrome()
            .navigationBarHidden(true)
            // Full-screen cover (over the tab bar) instead of a push: the bar is never hidden/removed, so it is never re-templated gray on return (tvOS 26). See detailCover.
            .detailCover(item: $selectedAlbum) { album in
                AlbumDetailView(album: album)
            }
        }
        .task {
            await viewModel.load(using: dependencies)
            // Do NOT force focus into the grid: entering a tab should leave focus on the tab bar
            // (descends only on press-down). Auto-setting focusedAlbumID yanked focus into content and
            // disrupted the engine when an album was open; it still tracks the focused card for styling, system-driven.
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if viewModel.isLoading {
            // .focusable so the tab keeps a focus target while loading; without one tvOS bounces focus to the previous tab.
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 400)
                .focusable()
        } else if let error = viewModel.displayedError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await viewModel.load(using: dependencies) }
                } label: {
                    Text("home.retry")
                        .font(.body)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, minHeight: 400)
        } else if viewModel.albums.isEmpty, !viewModel.songs.isEmpty {
            songList
        } else if viewModel.albums.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No albums found")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)
            .focusable()
        } else {
            let metrics = LayoutMetrics.current(hSizeClass)
            LazyVGrid(columns: [
                GridItem(
                    .adaptive(minimum: metrics.gridColumnMinimum(
                        cardScale: dependencies.appearancePreferences.cardScale)),
                    spacing: metrics.gridSpacing
                )
            ], spacing: gridRowSpacing) {
                ForEach(viewModel.albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        MediaCard(
                            item: album,
                            imageURL: dependencies.jellyfinImageService.posterURL(for: album),
                            style: .square,
                            isFocused: focusedAlbumID == album.id
                        )
                    }
                    .buttonStyle(GridCardButtonStyle())
                    .focused($focusedAlbumID, equals: album.id)
                }
            }
            .padding(.horizontal, metrics.gridInset)
            .padding(.vertical, hSizeClass == .compact ? 24 : 40)
        }
    }

    /// What a library without albums has to offer. Track numbers are deliberately not drawn here:
    /// they come from each file's own tag, so in a list that spans albums they count 1, 1, 2, 3, 2.
    private var songList: some View {
        let metrics = LayoutMetrics.current(hSizeClass)
        let coordinator = dependencies.musicPlaybackCoordinator
        return VStack(alignment: .leading, spacing: hSizeClass == .compact ? 20 : 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("music.songs.title")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("music.songs.ungrouped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                GlassActionButton(
                    title: "album.detail.play",
                    systemImage: "play.fill",
                    isProminent: true
                ) {
                    coordinator.play(queue: viewModel.songs, startAt: 0, contextTitle: Self.songsTitle)
                }

                GlassActionButton(
                    title: "album.detail.shuffle",
                    systemImage: "shuffle"
                ) {
                    coordinator.play(queue: viewModel.songs.shuffled(), startAt: 0, contextTitle: Self.songsTitle)
                }
            }
            .collapsesActionButtonLabel()

            LazyVStack(spacing: 8) {
                ForEach(Array(viewModel.songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(
                        song: song,
                        number: nil,
                        isCurrent: coordinator.currentItem?.id == song.id,
                        isPlaying: coordinator.isPlaying,
                        onSelect: {
                            // Tapping the already-playing track just opens the player; don't restart it.
                            if coordinator.currentItem?.id == song.id {
                                coordinator.requestNowPlayingPresentation()
                            } else {
                                coordinator.play(queue: viewModel.songs, startAt: index, contextTitle: Self.songsTitle)
                            }
                        }
                    )
                }
            }
        }
        .padding(.horizontal, metrics.gridInset)
        .padding(.vertical, hSizeClass == .compact ? 24 : 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The player's context line, so a track started from here is not titled after an album it has none of.
    private static var songsTitle: String { String(localized: "music.songs.title", defaultValue: "Songs") }

    /// tvOS keeps its 50pt row gap (byte-identical); other tiers track the metrics grid spacing.
    private var gridRowSpacing: CGFloat {
        #if os(tvOS)
        50
        #else
        LayoutMetrics.current(hSizeClass).gridSpacing
        #endif
    }
}
