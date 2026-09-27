import SwiftUI

/// What the focused program is, without opening anything. The strip holds the last program focused
/// in the grid, so moving focus to the ruler or the controls does not blank it.
struct GuideHeroView: View {
    let program: JellyfinProgram?
    let channel: JellyfinChannel?
    let metrics: GuideMetrics
    let tint: Color

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            artwork
            if let program {
                details(for: program)
            } else if let channel {
                // A channel with no EPG data still has an identity; a blank hero reads as a bug.
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("livetv.noProgramInfo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("livetv.guide.hero.empty")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 12)
        .frame(height: metrics.heroHeight, alignment: .top)
    }

    /// A program still is 16:9 and fills the thumb. A channel logo is not: filling it cropped the
    /// top and bottom clean off, which for a logo is the whole content. So the fallback fits and
    /// letterboxes against the surface colour instead.
    private var showsChannelLogo: Bool { programImageURL == nil }

    private var artwork: some View {
        AsyncCachedImage(
            url: programImageURL,
            fallbackURL: channelLogoURL
        ) { image in
            image.resizable()
                .aspectRatio(contentMode: showsChannelLogo ? .fit : .fill)
                .padding(showsChannelLogo ? 8 : 0)
        } placeholder: {
            Image(systemName: "tv")
                .font(.system(size: metrics.heroThumbSize.height * 0.3))
                .foregroundStyle(.tertiary)
        }
        .frame(width: metrics.heroThumbSize.width, height: metrics.heroThumbSize.height)
        .background(Color.Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func details(for program: JellyfinProgram) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(program.name)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)

            if let subtitle = subtitleLine(for: program) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if program.isAiring(at: Date()) {
                GuideHeroProgressBar(program: program, tint: tint)
            }

            if let overview = program.overview, !overview.isEmpty {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    /// Episode identity, channel, time window and genre on one line. Anything missing drops out
    /// rather than leaving an empty separator behind.
    private func subtitleLine(for program: JellyfinProgram) -> String? {
        var parts: [String] = []
        if let identity = program.identityLabel { parts.append(identity) }
        if let name = channel?.name ?? program.channelName { parts.append(name) }
        if let start = program.startDate, let end = program.endDate {
            let formatter = DateFormatter.guideShortTime
            parts.append("\(formatter.string(from: start)) - \(formatter.string(from: end))")
        }
        if let first = program.genres?.first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var programImageURL: URL? {
        guard let program, !program.isSynthesized else { return nil }
        return dependencies.jellyfinImageService.imageURL(
            itemID: program.id, imageType: .primary,
            tag: program.primaryImageTag,
            maxWidth: Int(metrics.heroThumbSize.width * 2))
    }

    private var channelLogoURL: URL? {
        guard let channel else { return nil }
        return dependencies.jellyfinImageService.imageURL(
            itemID: channel.id, imageType: .primary,
            tag: channel.primaryImageTag,
            maxWidth: Int(metrics.heroThumbSize.width * 2))
    }
}

/// Progress and time remaining for an airing program. Its own view with its own clock, so the
/// minute tick invalidates this bar and nothing above it.
private struct GuideHeroProgressBar: View {
    let program: JellyfinProgram
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let fraction = progress(at: context.date)
            HStack(spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(tint).frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(width: 160, height: 5)

                if let remaining = remaining(at: context.date) {
                    Text(verbatim: remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 14)
            .padding(.top, 2)
        }
        .frame(height: 16)
    }

    private func progress(at now: Date) -> CGFloat {
        guard let start = program.startDate, let end = program.endDate else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / total)))
    }

    /// The bar beside it says what the number counts, so no "left" (Sodalite#146, #165).
    private func remaining(at now: Date) -> String? {
        guard let end = program.endDate, end > now else { return nil }
        return end.timeIntervalSince(now).durationDisplay
    }
}

extension DateFormatter {
    /// Shared short-time formatter for the guide's SwiftUI chrome.
    static let guideShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
