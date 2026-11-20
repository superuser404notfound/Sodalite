#if !os(macOS)
// Player chrome for the UIKit host: it is display-only by construction, because
// PlayerHostController owns every press and moves a cursor through it. macOS has its own
// transport, whose controls handle their own clicks (Platforms/macOS/MacPlayerScreen.swift).
import SwiftUI

/// Feature #4: confirm/progress/error prompt for deleting an external subtitle.
/// DISPLAY-ONLY: renders from `subtitleDeleteState`/`subtitleDeleteFocus`;
/// PlayerHostController routes all remote input (host has user interaction
/// disabled like every player overlay).
struct SubtitleDeletePromptView: View {
    @Bindable var viewModel: PlayerViewModel
    var tint: Color

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 28) {
                content
            }
            .padding(48)
            .frame(width: 760)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.subtitleDeleteState {
        case .hidden:
            EmptyView()
        case .confirm:
            Text("player.subtitle.delete.title")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                button(
                    title: String(localized: "common.cancel", defaultValue: "Cancel"),
                    focused: viewModel.subtitleDeleteFocus == .cancel,
                    destructive: false
                )
                button(
                    title: String(localized: "player.subtitle.delete.confirm", defaultValue: "Delete"),
                    focused: viewModel.subtitleDeleteFocus == .delete,
                    destructive: true
                )
            }
        case .deleting:
            ProgressView()
            Text("player.subtitle.delete.deleting")
                .foregroundStyle(.secondary)
        case .error(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func button(title: String, focused: Bool, destructive: Bool) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .padding(.horizontal, 36)
            .padding(.vertical, 14)
            .foregroundStyle(focused ? .black : (destructive ? .red : .primary))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(focused ? (destructive ? Color.Theme.destructive : tint) : Color.Theme.restFillStrong)
            )
    }
}
#endif
