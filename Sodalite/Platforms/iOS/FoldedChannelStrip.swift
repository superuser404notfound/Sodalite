import SwiftUI

/// The channel lineup as one row of chips, below the fold of a standing iPhone Duo during Live TV:
/// the picture plays above, and a tap on a chip tunes that channel. Same lineup and same commit the
/// remote's up/down zap uses (`PlayerViewModel.zap(toChannel:)`).
struct FoldedChannelStrip: View {
    let viewModel: PlayerViewModel

    var body: some View {
        let current = viewModel.zapTarget?.id ?? viewModel.liveChannel?.id
        let skipped = viewModel.zapSkipsChannelIDs?() ?? []
        let channels = (viewModel.zapLineup?.channels ?? [])
            .filter { $0.id == viewModel.liveChannel?.id || !skipped.contains($0.id) }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(channels) { channel in
                        chip(channel, isCurrent: channel.id == current)
                            .id(channel.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onAppear {
                viewModel.loadZapLineupIfNeeded()
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
            .onChange(of: current) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: channels.count) { _, _ in
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .frame(height: 56)
    }

    private func chip(_ channel: JellyfinChannel, isCurrent: Bool) -> some View {
        Button {
            guard !isCurrent else { return }
            viewModel.zap(toChannel: channel.id)
        } label: {
            HStack(spacing: 8) {
                if let number = channel.channelNumber {
                    Text(number)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? .white : .white.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let program = channel.currentProgram?.name {
                        Text(program)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: 220, minHeight: 48, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.Theme.restFill))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
