#if os(tvOS)
import AetherEngine
import SwiftUI

/// Sodalite#175: two to four live channels at once. Audio follows focus, a click opens the tile full
/// screen, a hold offers change and remove, Back returns to one player.
struct MultiviewView: View {
    let coordinator: LiveMultiviewCoordinator

    @FocusState private var focusedTile: UUID?
    @FocusState private var addFocused: Bool
    @State private var overlays = MultiviewOverlayVisibility()

    private static let padding: CGFloat = 40
    private static let spacing: CGFloat = 24
    private static let addButtonHeight: CGFloat = 96

    private var session: MultiviewSession { coordinator.session }
    private var tint: Color { coordinator.theme.palette.control.color }

    var body: some View {
        @Bindable var coordinator = coordinator
        grid
            .background(Color.black.ignoresSafeArea())
            .tint(tint)
            .environment(\.appearanceTheme, coordinator.theme)
            .defaultFocus($focusedTile, session.audibleTileID)
            .onChange(of: focusedTile) { _, tile in
                guard let tile else { return }
                session.focusDidMove(to: tile)
            }
            .task(id: focusedTile) {
                overlays.focusChanged(to: focusedTile, now: .now)
            }
            .task(id: session.audibleTileID) {
                overlays.audioArrived(on: session.audibleTileID, now: .now)
            }
            .task(id: overlays.revision) {
                guard let deadline = overlays.deadline else { return }
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                overlays.expire(now: .now)
            }
            .onExitCommand { coordinator.end() }
            // Nothing to pause on a grid; pinned so the press does not reach a tile's player.
            .onPlayPauseCommand {}
            .menuPresentation(item: $coordinator.pickerRequest) { request in
                MultiviewChannelPicker(
                    channels: coordinator.pickerChannels(),
                    tint: tint,
                    onSelect: { coordinator.choose($0, for: request) }
                )
                .onAppear { coordinator.loadLineupIfNeeded() }
            }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let tiles = session.tiles
            let columnCount = MultiviewLayout.columns(tileCount: tiles.count)
            let showsAddTile = MultiviewLayout.showsAddTile(tileCount: tiles.count)
            let showsAddButton = MultiviewLayout.showsAddButton(tileCount: tiles.count)
            let cells = tiles.count + (showsAddTile ? 1 : 0)
            let rows = max(1, Int((Double(cells) / Double(columnCount)).rounded(.up)))
            let size = Self.tileSize(
                in: proxy.size, columns: columnCount, rows: rows,
                reservedHeight: showsAddButton ? Self.addButtonHeight + Self.spacing : 0)

            VStack(spacing: Self.spacing) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(size.width), spacing: Self.spacing), count: columnCount),
                    spacing: Self.spacing
                ) {
                    ForEach(tiles) { tile in
                        tileView(tile, size: size)
                    }
                    if showsAddTile {
                        addTile(size: size)
                    }
                }
                if showsAddButton {
                    addButton
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Self.padding)
        .ignoresSafeArea()
    }

    /// The largest 16:9 tile that fits the grid on screen, a reserved strip below it included.
    static func tileSize(in available: CGSize, columns: Int, rows: Int, reservedHeight: CGFloat) -> CGSize {
        let width = (available.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (available.height - reservedHeight - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        let fitted = min(width, height * 16 / 9)
        return CGSize(width: max(0, fitted), height: max(0, fitted * 9 / 16))
    }

    // MARK: - Tiles

    private func tileView(_ tile: MultiviewTile, size: CGSize) -> some View {
        let vm = tile.viewModel
        let isFocused = focusedTile == tile.id
        let failure = LiveMultiviewCoordinator.tileFailure(
            refusal: vm.tileRefusal, errorTitle: vm.errorTitle, errorMessage: vm.errorMessage)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let showInfo = overlays.isVisible(tile.id) && failure == nil
        let showSpeaker = overlays.isVisible(tile.id) && session.audibleTileID == tile.id && session.tiles.count > 1
        return ZStack(alignment: .bottomLeading) {
            AetherPlayerSurface(engine: vm.player)
            if let failure {
                failureOverlay(failure)
            }
            channelLabel(tile.currentChannel)
                .opacity(showInfo ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showInfo)
                .allowsHitTesting(false)
                .accessibilityHidden(!showInfo)
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .padding(12)
                .background(Color.Theme.scrim, in: Circle())
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(showSpeaker ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showSpeaker)
                .allowsHitTesting(false)
                .accessibilityHidden(!showSpeaker)
        }
        .frame(width: size.width, height: size.height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            coordinator.tileFrames[tile.id] = frame
        }
        .background(Color.black)
        .clipShape(shape)
        .overlay(shape.stroke(.tint, lineWidth: 4).opacity(isFocused ? 1 : 0))
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .focusable(true)
        .focused($focusedTile, equals: tile.id)
        .stableTap(isFocused: isFocused, longPressOpensMenu: true) {
            coordinator.showFullScreen(tile.id)
        }
        .contextMenu {
            Button {
                coordinator.pickerRequest = .replace(tile.id)
            } label: {
                Label(String(localized: "multiview.changeChannel", defaultValue: "Change channel"),
                      systemImage: "arrow.left.arrow.right")
            }
            Button(role: .destructive) {
                coordinator.remove(tile.id)
            } label: {
                Label(String(localized: "multiview.remove", defaultValue: "Remove"), systemImage: "xmark")
            }
            if session.canAddTile {
                Button {
                    coordinator.pickerRequest = .add
                } label: {
                    Label(String(localized: "multiview.addChannel", defaultValue: "Add channel"), systemImage: "plus")
                }
            }
        }
    }

    private func channelLabel(_ channel: JellyfinChannel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if let number = channel.channelNumber, !number.isEmpty {
                    Text(number)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let program = channel.currentProgram?.name, !program.isEmpty {
                Text(program)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.Theme.scrim, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(16)
    }

    private func failureOverlay(_ failure: LiveMultiviewCoordinator.TileFailure) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tv.slash")
                .font(.title2)
            if !failure.title.isEmpty {
                Text(failure.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            Text(failure.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(String(localized: "multiview.holdHint", defaultValue: "Hold to choose another channel"))
                .font(.caption)
                .foregroundStyle(.tint)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Theme.scrimHeavy)
    }

    // MARK: - Adding

    private func addTile(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Image(systemName: "plus")
            .font(.system(size: 64, weight: .semibold))
            .foregroundStyle(addFocused ? Color.black : Color.primary)
            .frame(width: size.width, height: size.height)
            .background(addFocused ? tint : Color.Theme.restFillStrong, in: shape)
            .accessibilityLabel(String(localized: "multiview.addChannel", defaultValue: "Add channel"))
            .focusable(true)
            .focused($addFocused)
            .stableTap(isFocused: addFocused) { coordinator.pickerRequest = .add }
    }

    private var addButton: some View {
        Label(String(localized: "multiview.addChannel", defaultValue: "Add channel"), systemImage: "plus")
            .font(.headline)
            .foregroundStyle(addFocused ? Color.black : Color.primary)
            .padding(.horizontal, 40)
            .frame(height: Self.addButtonHeight)
            .background(addFocused ? tint : Color.Theme.restFillStrong, in: Capsule())
            .focusable(true)
            .focused($addFocused)
            .stableTap(isFocused: addFocused) { coordinator.pickerRequest = .add }
    }
}

/// The channel list for adding a tile or changing one, without the channels already on screen.
private struct MultiviewChannelPicker: View {
    /// Nil while the lineup is loading.
    let channels: [JellyfinChannel]?
    let tint: Color
    let onSelect: (JellyfinChannel) -> Void

    @FocusState private var focusedChannel: String?

    var body: some View {
        VStack(spacing: 36) {
            Text(String(localized: "multiview.chooseChannel", defaultValue: "Choose a channel"))
                .font(.title2)
                .fontWeight(.semibold)

            if let channels {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(channels) { channel in
                            row(channel)
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding(.vertical, 8)
                }
                .defaultFocus($focusedChannel, channels.first?.id)
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ channel: JellyfinChannel) -> some View {
        let isFocused = focusedChannel == channel.id
        return HStack(spacing: 24) {
            Text(channel.channelNumber ?? "")
                .font(.body.monospacedDigit())
                .frame(width: 100, alignment: .trailing)
                .opacity(0.75)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let program = channel.currentProgram?.name, !program.isEmpty {
                    Text(program)
                        .font(.caption)
                        .opacity(0.75)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? tint : Color.Theme.restFillStrong)
        )
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .focusable(true)
        .focused($focusedChannel, equals: channel.id)
        .stableTap(isFocused: isFocused) { onSelect(channel) }
    }
}
#endif
