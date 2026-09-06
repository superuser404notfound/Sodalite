import SwiftUI

// MARK: - MediaSource display helpers

extension MediaSource {
    var primaryVideoStream: MediaStream? {
        mediaStreams?.first { $0.type == .video }
    }

    /// "4K"/"1080p" etc. Normalizes height to a 16:9-equivalent width so a 2.39:1 scope master still reads as the right tier.
    var resolutionLabel: String? {
        guard let v = primaryVideoStream else { return nil }
        let w = v.width ?? 0
        let h = v.height ?? 0
        let dim = max(w, h * 16 / 9)
        switch dim {
        case 3840...: return "4K"
        case 2560...: return "1440p"
        case 1920...: return "1080p"
        case 1280...: return "720p"
        default: return h > 0 ? "\(h)p" : nil
        }
    }

    var codecLabel: String? {
        primaryVideoStream?.codec?.uppercased()
    }

    var sizeLabel: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Version-row label: prefers the server's version name (Jellyfin's `MediaSource.Name`, e.g. "Directors Cut"), appends derived specs the name doesn't convey, falls back to container so a row is never blank.
    var versionLabel: String {
        var parts: [String] = []
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(name)
        }
        for spec in [resolutionLabel, codecLabel, sizeLabel].compactMap({ $0 }) {
            if !parts.contains(where: { $0.caseInsensitiveCompare(spec) == .orderedSame }) {
                parts.append(spec)
            }
        }
        if parts.isEmpty, let container, !container.isEmpty {
            parts.append(container.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    /// Sort key for "highest quality first": bitrate, else pixel count.
    var qualityRank: Int {
        if let bitrate, bitrate > 0 { return bitrate }
        let v = primaryVideoStream
        return (v?.width ?? 0) * (v?.height ?? 0)
    }
}

// MARK: - Version picker presentation payload

/// Drives the version sheet via `.sheet(item:)`. Carrying sources in the item (not a separate `@State` array via `.sheet(isPresented:)`) avoids SwiftUI's stale-content race where the closure captures the initial empty array.
struct VersionPickerChoice: Identifiable {
    let id = UUID()
    let item: JellyfinItem
    let sources: [MediaSource]
    let fromBeginning: Bool
    /// Series-only focus-restoration origin flag; ignored by movie detail.
    let fromPlayButton: Bool
}

// MARK: - Version picker sheet

/// Multi-source version picker (highest quality first, top focused); `onSelect` gets the chosen source, dismissing without one cancels playback.
struct VersionPickerSheet: View {
    let sources: [MediaSource]
    let tintColor: Color
    let onSelect: (MediaSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// iPhone (compact) shrinks the tvOS-scaled padding/fonts/row heights; tvOS/iPad keep full size.
    private var isCompact: Bool { hSizeClass == .compact }

    private var sorted: [MediaSource] {
        sources.sorted { $0.qualityRank > $1.qualityRank }
    }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 36) {
            Text("detail.version.title")
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(spacing: isCompact ? 12 : 16) {
                    ForEach(sorted) { source in
                        row(source)
                    }
                }
                .frame(
                    maxWidth: 760,
                    minHeight: sorted.count > 1
                        ? min(CGFloat(sorted.count) * (isCompact ? 64 : 140), isCompact ? 360 : 720)
                        : nil
                )
                .padding(.vertical, 8)
            }
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .onAppear { focusedID = sorted.first?.id }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func row(_ source: MediaSource) -> some View {
        let isFocused = focusedID == source.id
        return HStack {
            Text(source.versionLabel)
                .font(.body)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isCompact ? 18 : 32)
        .padding(.vertical, isCompact ? 14 : 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? tintColor : Color.Theme.surface)
        )
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .focusable(true)
        .focused($focusedID, equals: source.id)
        .stableTap(isFocused: isFocused) {
            onSelect(source)
            dismiss()
        }
    }
}
