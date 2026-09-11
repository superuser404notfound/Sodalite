import SwiftUI

/// Collects per-card heights so every TechCard sizes to the tallest sibling; reduce picks the max.
private struct TechCardMaxHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TechInfoBox: View {
    let item: JellyfinItem
    /// The version the page is describing. A multi-version item used to strand these cards on its
    /// first source, so the strip said 1080p while the viewer had picked the 4K (Sodalite#139).
    var sourceID: String?

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    @State private var maxCardHeight: CGFloat = 0

    private var streams: [MediaStream] {
        item.effectiveMediaStreams(id: sourceID) ?? []
    }

    private var videoStream: MediaStream? {
        streams.first { $0.type == .video }
    }

    private var audioStreams: [MediaStream] {
        streams.filter { $0.type == .audio }
    }

    private var subtitleStreams: [MediaStream] {
        streams.filter { $0.type == .subtitle }
    }

    private var mediaSource: MediaSource? {
        item.effectiveMediaSource(id: sourceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("detail.techInfo")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    if let video = videoStream { videoCard(video) }
                    if let audio = audioStreams.first { audioCard(audio) }
                    if let source = mediaSource { fileCard(source) }
                    if !subtitleStreams.isEmpty { subtitleCard() }
                }
                .padding(.horizontal, metrics.rowInset)
                .padding(.vertical, 12)
            }
        }
        .onPreferenceChange(TechCardMaxHeightKey.self) { newValue in
            // Grow-only so repopulating cards don't shrink the strip mid-scroll.
            if newValue > maxCardHeight { maxCardHeight = newValue }
        }
    }

    // MARK: - Video

    private func videoCard(_ video: MediaStream) -> some View {
        TechCard(icon: "film", title: "detail.tech.video", height: maxCardHeight) {
            if let w = video.width, let h = video.height {
                TechRow(label: "detail.tech.resolution", value: "\(w)×\(h)")
            }
            if let codec = video.codec?.uppercased() {
                let profile = video.profile ?? ""
                TechRow(label: "detail.tech.codec", value: profile.isEmpty ? codec : "\(codec) \(profile)")
            }
            if let fps = video.realFrameRate ?? video.averageFrameRate {
                TechRow(label: "detail.tech.framerate", value: String(format: "%.2g fps", fps))
            }
            if let range = dynamicRangeLabel(video) {
                TechRow(label: "detail.tech.dynamicRange", value: range)
            }
        }
    }

    /// Dynamic-range label matching the player stats overlay: DV P<profile>, then VideoRangeType, falling back to the raw VideoRange string.
    private func dynamicRangeLabel(_ video: MediaStream) -> String? {
        if let dv = video.dvProfile {
            return "Dolby Vision P\(dv)"
        }
        switch video.videoRangeType?.uppercased() {
        case "HDR10":     return "HDR10"
        case "HDR10PLUS": return "HDR10+"
        case "HLG":       return "HLG"
        case "DOVI", "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR":
            return "Dolby Vision"
        case "SDR":       return "SDR"
        default:          return video.videoRange
        }
    }

    // MARK: - Audio

    private func audioCard(_ audio: MediaStream) -> some View {
        TechCard(icon: "speaker.wave.2", title: "detail.tech.audio", height: maxCardHeight) {
            if let codec = audio.codec?.uppercased() {
                TechRow(label: "detail.tech.codec", value: codec)
            }
            if let ch = audio.channels {
                TechRow(label: "detail.tech.channels", value: channelLayout(ch))
            }
            if let lang = audio.displayTitle ?? audio.language {
                TechRow(label: "detail.tech.language", value: lang)
            }
            if audioStreams.count > 1 {
                TechRow(label: "detail.tech.tracks", value: "\(audioStreams.count)")
            }
        }
    }

    // MARK: - File

    private func fileCard(_ source: MediaSource) -> some View {
        TechCard(icon: "doc", title: "detail.tech.file", height: maxCardHeight) {
            if let container = source.container?.uppercased() {
                TechRow(label: "detail.tech.format", value: container)
            }
            if let bitrate = source.bitrate {
                TechRow(label: "detail.tech.bitrate", value: formatBitrate(bitrate))
            }
            if let size = source.size {
                TechRow(label: "detail.tech.size", value: formatFileSize(size))
            }
            if let path = source.path, let filename = path.split(separator: "/").last {
                TechRow(label: "detail.tech.filename", value: String(filename))
            }
        }
    }

    // MARK: - Subtitles

    private func subtitleCard() -> some View {
        TechCard(icon: "captions.bubble", title: "detail.tech.subtitles", height: maxCardHeight) {
            TechRow(label: "detail.tech.tracks", value: "\(subtitleStreams.count)")

            ForEach(subtitleStreams.prefix(4)) { sub in
                if let lang = sub.displayTitle ?? sub.language {
                    HStack(spacing: 6) {
                        Text(lang)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if sub.isForced == true {
                            Text(String(localized: "tech.subtitles.forced", defaultValue: "F"))
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.tertiary))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Formatters

    private func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: String(localized: "tech.channels.mono", defaultValue: "Mono")
        case 2: String(localized: "tech.channels.stereo", defaultValue: "Stereo")
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels)ch"
        }
    }

    private func formatBitrate(_ bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return "\(bps / 1000) Kbps"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Tech Card (focusable)

struct TechCard<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    /// Shared height from the parent's PreferenceKey; 0 on the first pass (card sizes naturally so the preference can report), measured max on the second.
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    @FocusState private var isFocused: Bool
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.tint)

            content()
        }
        .padding(hSizeClass == .compact ? 16 : 24)
        .frame(width: hSizeClass == .compact ? 280 : 380, alignment: .topLeading)
        .background(
            GeometryReader { geo in
                // Report natural height upward; parent feeds the max back via `height`.
                Color.clear.preference(
                    key: TechCardMaxHeightKey.self,
                    value: geo.size.height
                )
            }
        )
        .frame(height: height > 0 ? height : nil, alignment: .topLeading)
        .background(
            // Material base for full-bleed backdrop contrast (see ExpandableTextBox).
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16)
                    .fill(isFocused ? .white.opacity(0.1) : .clear)
            }
        )
        .focusStroke(cornerRadius: 16, isFocused: isFocused)
        .focusResponse(.tile.flat, isFocused: isFocused)
        .focusable()
        .focused($isFocused)
    }
}

// MARK: - Tech Row

struct TechRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
