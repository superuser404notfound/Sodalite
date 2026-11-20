import SwiftUI

/// More Details (Sodalite#146): the full synopsis and the technical detail, behind the one ⓘ in the
/// action row.
///
/// This is what lets the page above it be sparse. The four-card tech strip it replaces sat on the
/// page itself, cost about a third of a screen and four focus stops, and was several presses from
/// where the viewer was deciding; a reader is where that belongs, and it can say MORE than the strip
/// did (every audio track, the whole subtitle list) because it has the room.
///
/// It carries no controls. Reading only, Back and Menu are the one affordance, so everything that
/// acts on the title stays in the action row where it is visible without a press.
struct DetailMoreOverlay: View {
    let title: String
    /// nil while the synopsis is spoiler-veiled: the reader shows technical facts, which are not
    /// spoilers, and the veil stays the page's job so there is one place to lift it.
    let synopsis: String?
    let facts: TechFacts
    /// Which copy these facts describe, when the item offers more than one.
    var versionLabel: String?
    @Binding var isPresented: Bool

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        ZStack {
            Color.Theme.scrimHeavy.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if let synopsis, !synopsis.isEmpty {
                        // Split for the same reason the full-text reader splits: focus scrolls a
                        // block's TOP into view, so a block taller than the screen hides its own
                        // tail (Sodalite#57).
                        ForEach(Array(TextBlockSplitter.split(synopsis).enumerated()), id: \.offset) { _, block in
                            MoreDetailsBlock {
                                Text(block)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    ForEach(facts.sections) { section in
                        MoreDetailsBlock {
                            sectionBody(section)
                        }
                    }
                }
                .padding(metrics.rowInset)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            #if !os(tvOS)
            VStack {
                HStack {
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(24)
                }
                Spacer()
            }
            #endif
        }
        // tvOS leaves with Menu, like the licences and changelog readers; a close button there would
        // only take the focus the text needs.
        .onExitCommandCompat { isPresented = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(2)
            if let versionLabel, !versionLabel.isEmpty {
                // Which copy this describes. Without it the numbers change silently when the viewer
                // picks another version, and only someone who memorised them notices (Sodalite#139).
                Text(versionLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func sectionBody(_ section: TechFacts.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(section.title, systemImage: section.icon)
                .font(.caption)
                .foregroundStyle(.tint)

            ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    label(row.label)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !row.value.isEmpty {
                        Text(row.value)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func label(_ label: TechFacts.RowLabel) -> some View {
        switch label {
        case .key(let key): Text(key)
        case .verbatim(let text): Text(verbatim: text)
        }
    }
}

/// One reachable block of the reader. Focusable on tvOS and nowhere else: a focusable ScrollView
/// does not scroll on the remote, focus moving between its children does, so a reader made of one
/// long Text simply stands still (Sodalite#57).
private struct MoreDetailsBlock<Content: View>: View {
    @ViewBuilder let content: () -> Content

    // @FocusState, not @Environment(\.isFocused): the latter does not propagate into a plain
    // .focusable() view on tvOS.
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(tvOS)
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.Theme.focusFill : .clear)
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .focusableSurface()
            .focused($isFocused)
        #else
        content()
        #endif
    }
}
