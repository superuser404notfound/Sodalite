import SwiftUI

enum SpoilerVeilStyle: Sendable {
    /// Episode stills and other artwork.
    case image
    /// Synopsis text.
    case text

    var blurRadius: CGFloat {
        switch self {
        case .image: 30
        case .text: 6
        }
    }

    var surface: SpoilerPolicy.Surface {
        switch self {
        case .image: .artwork
        case .text: .text
        }
    }
}

/// Sodalite#50. The environment reads live here so SpoilerPolicy stays a pure value and call
/// sites stay one line.
enum SpoilerReveal {
    /// Defaults to the text surface, which is also the base decision: anything veiled at all has
    /// its description veiled, while artwork narrows further.
    static func isHidden(
        _ item: JellyfinItem,
        dependencies: DependencyContainer,
        appState: AppState,
        surface: SpoilerPolicy.Surface = .text
    ) -> Bool {
        dependencies.spoilerPolicy(userID: appState.activeUser?.id).isHidden(item, surface: surface)
    }

    static func reveal(_ item: JellyfinItem, dependencies: DependencyContainer, appState: AppState) {
        let policy = dependencies.spoilerPolicy(userID: appState.activeUser?.id)
        dependencies.spoilerRevealMemory.reveal(policy.key(for: item))
    }

    /// Sodalite#222. Whether `hide` would veil this item again.
    static func canHide(_ item: JellyfinItem, dependencies: DependencyContainer, appState: AppState) -> Bool {
        dependencies.spoilerPolicy(userID: appState.activeUser?.id).isManuallyRevealed(item)
    }

    static func hide(_ item: JellyfinItem, dependencies: DependencyContainer, appState: AppState) {
        let policy = dependencies.spoilerPolicy(userID: appState.activeUser?.id)
        dependencies.spoilerRevealMemory.hide(policy.key(for: item))
    }
}

private struct SpoilerVeilModifier: ViewModifier {
    let isHidden: Bool
    let style: SpoilerVeilStyle

    func body(content: Content) -> some View {
        if isHidden {
            content
                .blur(radius: style.blurRadius)
                .overlay {
                    if style == .image {
                        Image(systemName: "eye.slash")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                // Blurring only hides it from sight. Without collapsing the subtree into one
                // relabelled element, VoiceOver would still read the spoiler out loud.
                .accessibilityElement()
                .accessibilityLabel(Text("spoiler.hidden"))
        } else {
            content
        }
    }
}

private struct SpoilerItemVeilModifier: ViewModifier {
    let item: JellyfinItem
    let style: SpoilerVeilStyle
    /// Sodalite#66. Off where the caller already replaced the artwork with something that carries
    /// no plot, so blurring it would hide nothing and only cost the user the art.
    let veils: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    func body(content: Content) -> some View {
        content.modifier(
            SpoilerVeilModifier(
                isHidden: veils && SpoilerReveal.isHidden(
                    item,
                    dependencies: dependencies,
                    appState: appState,
                    surface: style.surface
                ),
                style: style
            )
        )
    }
}

extension View {
    /// Veils this view when the item is an unseen episode or movie under the user's settings.
    /// `veils: false` opts a call site out, for artwork that is not the item's own (Sodalite#66).
    func spoilerVeil(for item: JellyfinItem, style: SpoilerVeilStyle, veils: Bool = true) -> some View {
        modifier(SpoilerItemVeilModifier(item: item, style: style, veils: veils))
    }

    /// Veils on a decision the caller already made, for surfaces outside the environment: the
    /// player injects its policy through PlayerViewModel instead.
    func spoilerVeil(isHidden: Bool, style: SpoilerVeilStyle) -> some View {
        modifier(SpoilerVeilModifier(isHidden: isHidden, style: style))
    }
}
