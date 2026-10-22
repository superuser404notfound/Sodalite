import SwiftUI

struct ExpandableTextBox: View {
    let text: String
    /// Sodalite#50. nil keeps the component exactly as it was for callers with nothing to spoil.
    var spoilerItem: JellyfinItem?
    /// tvOS: where focus goes when the viewer moves up out of the box (see onFocusMoveUp). Detail
    /// pages hand it their play button; nil keeps stock navigation for every other caller.
    var onFocusMovedUp: (() -> Void)?
    /// tvOS: reports whether the box holds focus, so a detail page can suppress its secondary
    /// buttons for that time (see focusSuppressed) and the up-move has nowhere wrong to land.
    var onFocusChanged: ((Bool) -> Void)?
    /// tvOS: set true from outside to hand the box focus. The box owns its `@FocusState`, so a
    /// caller that has to steer focus here (the series page redirects an up-move out of the episode
    /// row onto the season synopsis) needs this relay; the box clears the flag once it has focus.
    var focusRequest: Binding<Bool>?

    @State private var showFullText = false
    @FocusState private var isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    private var isSpoilerHidden: Bool {
        guard let spoilerItem else { return false }
        return SpoilerReveal.isHidden(spoilerItem, dependencies: dependencies, appState: appState)
    }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 110)
            // Sodalite#50: only the text is veiled, the material and the focus stroke stay sharp.
            .spoilerVeil(isHidden: isSpoilerHidden, style: .text)
            .padding(20)
            .background(
                // Material base (not a faint white tint) so body text keeps contrast over bright full-bleed artwork (Sodalite#15).
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isFocused ? .white.opacity(0.1) : .clear)
                }
            )
            .focusStroke(cornerRadius: 16, isFocused: isFocused)
            .focusResponse(.inline, isFocused: isFocused)
            .focusableSurface()
            .focused($isFocused)
            .stableTap(isFocused: isFocused) {
                // Sodalite#50: same two-step as EpisodeSynopsisBox, uncover first, expand second.
                if let spoilerItem, isSpoilerHidden {
                    SpoilerReveal.reveal(spoilerItem, dependencies: dependencies, appState: appState)
                    return
                }
                showFullText = true
            }
            .onFocusMoveUp(onFocusMovedUp)
            .onChange(of: isFocused) { _, focused in onFocusChanged?(focused) }
            .onChange(of: focusRequest?.wrappedValue ?? false) { _, requested in
                guard requested else { return }
                // Same defer as every other cross-view focus write on this page: a @FocusState write
                // that rides the tick which just committed another element's focus is swallowed.
                deferOnMain(by: 0.03) {
                    isFocused = true
                    focusRequest?.wrappedValue = false
                }
            }
            // The box can leave the tree while it holds focus (the series page rebuilds it per
            // episode); without this the caller would keep its buttons suppressed for good.
            .onDisappear { onFocusChanged?(false) }
            .fullScreenCoverCompat(isPresented: $showFullText) {
                TextOverlay(text: text, isPresented: $showFullText)
            }
    }
}

struct TextOverlay: View {
    let text: String
    @Binding var isPresented: Bool

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ZStack {
            Color.Theme.scrimHeavy.ignoresSafeArea()

            #if os(tvOS)
            // A focusable ScrollView does not scroll on the remote; focus moving between its
            // children does. One long Text is a single target, so a biography that overflows the
            // screen simply stood still (Sodalite#57).
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(TextBlockSplitter.split(text).enumerated()), id: \.offset) { _, block in
                        FocusableTextBlock(text: block)
                    }
                }
                .padding(60)
                .frame(maxWidth: 1200)
            }
            #else
            // A tap anywhere closes the reader: the text is not selectable, and the bare glyph
            // that used to be the only way out had to be hit to the point (reported on the iPhone).
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, hSizeClass == .compact ? 24 : 60)
                    .padding(.vertical, 60)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.done"))
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
            }
            #endif
        }
        // tvOS leaves with Menu, like the licences and changelog readers; a close button would only
        // take the focus the text needs.
        .onExitCommandCompat { isPresented = false }
    }
}

#if os(tvOS)
/// One block of the overlay text, focusable so the remote can step (and thereby scroll) through it.
private struct FocusableTextBlock: View {
    let text: String

    // @FocusState not @Environment(\.isFocused): the latter doesn't propagate into a plain
    // .focusable() View on tvOS.
    @FocusState private var isFocused: Bool

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.Theme.focusFill : .clear)
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .focusableSurface()
            .focused($isFocused)
    }
}
#endif

/// Cuts long text into blocks a single tvOS focus step can show. Focus scrolls a block's *top* into
/// view, so a block taller than the screen hides its own tail, which is the whole defect this
/// exists to avoid: paragraphs first, sentences inside a paragraph that is still too long, words
/// inside a sentence that is (an unpunctuated wall of text still has to scroll).
enum TextBlockSplitter {
    /// Well under a screen of tvOS body text at 1200pt wide (~2000 characters), and large enough to
    /// leave ordinary prose paragraphs whole.
    static let maxBlockLength = 700

    static func split(_ text: String) -> [String] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { pack(units(of: $0)) }
        // Never nothing: blank text would leave the overlay without a focus target, and on tvOS
        // that is a screen the Menu button cannot leave.
        return blocks.isEmpty ? [text] : blocks
    }

    /// Sentences, and words for a sentence that is longer than a block on its own.
    private static func units(of paragraph: String) -> [String] {
        guard paragraph.count > maxBlockLength else { return [paragraph] }
        var sentences: [String] = []
        // The enclosing range, not the substring: it carries the separators, so the pieces rejoin
        // into the paragraph exactly.
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { _, _, enclosing, _ in
            sentences.append(String(paragraph[enclosing]))
        }
        if sentences.isEmpty { sentences = [paragraph] }
        return sentences.flatMap { $0.count > maxBlockLength ? splitOnWords($0) : [$0] }
    }

    private static func splitOnWords(_ sentence: String) -> [String] {
        var blocks: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > maxBlockLength, !current.isEmpty {
                blocks.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func pack(_ units: [String]) -> [String] {
        var blocks: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty, current.count + unit.count > maxBlockLength {
                blocks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += unit
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { blocks.append(last) }
        return blocks
    }
}
