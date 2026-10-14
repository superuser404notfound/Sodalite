import SwiftUI

/// The synopsis teaser inside the first viewport's panel (Sodalite#146).
///
/// The plot used to be the first child BELOW the fold, so the page a viewer met carried the studio
/// and little else of substance. Three lines up here answer "what is this" before the first scroll;
/// the full text stays reachable below.
///
/// The height is reserved rather than measured, and that is the point of the component. The panel
/// sits in a bottom-aligned, viewport-tall first page, so a block that grows when the detail fetch
/// lands pushes the button row down after first paint (Sodalite#15), and a panel whose height
/// varies within one mode lands the page at a different scroll offset every time it is opened
/// (the episode-vs-series case). A fixed line count with `reservesSpace` removes both.
struct DetailHeroSynopsis: View {
    let text: String?
    /// Whether the fetch that could still deliver an overview is in flight. Only then is empty
    /// space held: a title that settles without a synopsis collapses the block instead of keeping
    /// three blank lines, the same rule `DetailInfoRows` applies to its skeletons.
    var isPending: Bool = false
    /// Sodalite#50. The teaser is veiled by exactly the same rule as the box below the fold, or a
    /// hidden episode synopsis would simply be printed one screen higher.
    var spoilerItem: JellyfinItem?

    @Environment(\.verticalSizeClass) private var vSizeClass
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    /// Two lines in a short viewport (iPhone landscape), where the first page is not viewport-locked
    /// and every added line pushes the action row further past the fold, and in the upright
    /// iPhone's column, which shares its first screen with the poster. The rest is behind the info
    /// button.
    private var lineCount: Int {
        vSizeClass == .compact || hSizeClass == .compact ? 2 : 3
    }

    private var isSpoilerHidden: Bool {
        guard let spoilerItem else { return false }
        return SpoilerReveal.isHidden(spoilerItem, dependencies: dependencies, appState: appState)
    }

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(lineCount, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .spoilerVeil(isHidden: isSpoilerHidden, style: .text)
        } else if isPending {
            // Reserved, not a skeleton. The panel already carries a material, and three grey bars
            // inside it read as more chrome than the fetch they stand in for is worth.
            Text(verbatim: " ")
                .font(.body)
                .lineLimit(lineCount, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
