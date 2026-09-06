import SwiftUI

/// Recordings + scheduled timers (the "Aufnahmen" segment). Recordings are plain JellyfinItems and
/// launch the normal VOD player.
struct RecordingsView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    let model: RecordingsViewModel
    let tint: Color

    @State private var playerItem: JellyfinItem?
    @State private var isPlayerPresented = false
    @State private var recordingToDelete: JellyfinItem?

    private var imageService: JellyfinImageService { dependencies.jellyfinImageService }
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    /// tvOS/iPad keep the fixed 4-column grid; compact goes adaptive so landscape tiles fit ~2-up
    /// on a phone (the poster-scaled gridMinimum would pack three cramped columns).
    private var recordingColumns: [GridItem] {
        if hSizeClass == .compact {
            [GridItem(.adaptive(minimum: 160), spacing: metrics.gridSpacing, alignment: .leading)]
        } else {
            Array(repeating: GridItem(.flexible(), spacing: 32), count: 4)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: hSizeClass == .compact ? 28 : 40) {
                recordingsSection
                scheduledSection
                seriesSection
            }
            .padding(.horizontal, hSizeClass == .compact ? metrics.gridInset : 80)
            .padding(.vertical, hSizeClass == .compact ? 24 : 40)
        }
        .task { await model.load() }
        .overlay {
            if let userID = dependencies.activeUserID {
                PlayerLauncher(
                    isPresented: $isPlayerPresented,
                    item: playerItem,
                    startFromBeginning: false,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: userID),
                    cachedPlaybackInfo: nil
                )
                .allowsHitTesting(false)
            }
        }
        .alert(
            Text("livetv.recordings.deleteConfirm"),
            isPresented: Binding(
                get: { recordingToDelete != nil },
                set: { if !$0 { recordingToDelete = nil } }
            )
        ) {
            Button("livetv.recordings.delete", role: .destructive) {
                if let item = recordingToDelete {
                    Task { await model.deleteRecording(item) }
                }
                recordingToDelete = nil
            }
            Button("common.cancel", role: .cancel) { recordingToDelete = nil }
        }
        .alert(
            Text("livetv.recording.error.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Recordings

    @ViewBuilder
    private var recordingsSection: some View {
        Text("livetv.recordings.title").font(.title2).bold()
        if model.recordings.isEmpty && !model.isLoading {
            Text("livetv.recordings.empty").foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: recordingColumns,
                      alignment: .leading, spacing: hSizeClass == .compact ? metrics.gridSpacing : 32) {
                ForEach(model.recordings) { item in
                    RecordingCard(
                        item: item,
                        imageURL: imageService.imageURL(
                            itemID: item.id, imageType: .primary,
                            tag: item.imageTags?.primary, maxWidth: 600),
                        isInProgress: model.isInProgress(item),
                        tint: tint,
                        onPlay: {
                            playerItem = item
                            isPlayerPresented = true
                        },
                        onDelete: { recordingToDelete = item }
                    )
                }
            }
        }
    }

    // MARK: - Scheduled

    @ViewBuilder
    private var scheduledSection: some View {
        Text("livetv.recordings.scheduled").font(.title2).bold()
        if model.timers.isEmpty && !model.isLoading {
            Text("livetv.recordings.scheduledEmpty").foregroundStyle(.secondary)
        } else {
            ForEach(model.timers) { timer in
                TimerRow(
                    title: timer.name ?? "",
                    subtitle: timerSubtitle(timer),
                    isSeries: timer.seriesTimerId != nil,
                    tint: tint,
                    onCancel: { Task { await model.cancelTimer(timer) } }
                )
            }
        }
    }

    @ViewBuilder
    private var seriesSection: some View {
        if !model.seriesTimers.isEmpty {
            Text("livetv.recordings.seriesTimers").font(.title2).bold()
            ForEach(model.seriesTimers) { timer in
                TimerRow(
                    title: timer.name ?? "",
                    subtitle: timer.channelName,
                    isSeries: true,
                    tint: tint,
                    onCancel: { Task { await model.cancelSeriesTimer(timer) } }
                )
            }
        }
    }

    private func timerSubtitle(_ timer: LiveTvTimer) -> String? {
        var parts: [String] = []
        if let channel = timer.channelName { parts.append(channel) }
        if let start = timer.startDate {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 16:9 recording card: backdrop, title, runtime line, in-progress badge. Select plays; delete goes
/// through a dedicated focusable trash chip.
private struct RecordingCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    /// Server-confirmed via IsInProgress (see RecordingsViewModel.inProgressIDs); item.status stays empty on modern Jellyfin recordings.
    let isInProgress: Bool
    let tint: Color
    let onPlay: () -> Void
    let onDelete: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool
    @FocusState private var deleteFocused: Bool

    /// tvOS keeps the 180pt backdrop; compact uses the phone landscape height so tiles aren't oversized.
    private var imageHeight: CGFloat {
        hSizeClass == .compact ? LayoutMetrics.current(hSizeClass).landscapeSize.height : 180
    }

    /// "92 min" runtime; JellyfinItem has no display-ready date (premiereDate is a raw string), so runtime stands in.
    private var runtimeLabel: String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let minutes = Int(ticks / 600_000_000)
        guard minutes > 0 else { return nil }
        return "\(minutes) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                AsyncCachedImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.Theme.restFill)
                }
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focused ? tint : Color.Theme.hairline,
                                      lineWidth: focused ? 4 : 1)
                )
                if isInProgress {
                    Label("livetv.recordings.inProgress", systemImage: "record.circle")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.Theme.recording.opacity(0.85)))
                        .padding(8)
                }
            }
            .scaleEffect(focused ? 1.05 : 1.0)
            .focusable()
            .focused($focused)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .stableTap(isFocused: focused) { onPlay() }

            Text(item.name).font(.headline).lineLimit(1)
            HStack {
                if let runtimeLabel {
                    Text(runtimeLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(deleteFocused ? Color.black : .secondary)
                    .padding(8)
                    .background(Circle().fill(deleteFocused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear)))
                    .focusable()
                    .focused($deleteFocused)
                    .stableTap(isFocused: deleteFocused) { onDelete() }
            }
        }
    }
}

private struct TimerRow: View {
    let title: String
    let subtitle: String?
    let isSeries: Bool
    let tint: Color
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isSeries ? "record.circle.fill" : "record.circle")
                .foregroundStyle(Color.Theme.recording)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("livetv.recordings.cancelTimer")
                .font(.caption.bold())
                .foregroundStyle(focused ? Color.black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(focused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.Theme.restFillStrong)))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(focused ? 0.10 : 0.04)))
        .focusable()
        .focused($focused)
        .stableTap(isFocused: focused) { onCancel() }
    }
}
