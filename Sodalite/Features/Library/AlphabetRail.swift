import SwiftUI

/// `#` + A to Z down the grid's trailing edge (Sodalite#86). tvOS: its own focus section, a focus
/// change reports the letter, select or a move left commits. iOS: a drag reports the letter under
/// the finger.
struct AlphabetRail: View {
    let letters: [String]
    let highlighted: String?
    /// Bumped by the owner when a jump failed; shakes that letter.
    let rejected: (letter: String, attempt: Int)?
    let onLetter: (String) -> Void
    let onCommit: (String) -> Void

    #if os(tvOS)
    @FocusState private var focused: String?
    #else
    @State private var dragged: String?
    #endif

    var body: some View {
        #if os(tvOS)
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Button { onCommit(letter) } label: { label(letter, isActive: focused == letter) }
                    .buttonStyle(RailLetterButtonStyle())
                    .focused($focused, equals: letter)
            }
        }
        .focusSection()
        .onChange(of: focused) { _, letter in
            if let letter { onLetter(letter) }
        }
        .onMoveCommand { direction in
            if direction == .left, let focused { onCommit(focused) }
        }
        .accessibilityLabel(Text("library.alphabetRail.label"))
        #else
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    label(letter, isActive: dragged == letter)
                        .frame(maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let slot = Int(value.location.y / max(1, proxy.size.height) * CGFloat(letters.count))
                    let letter = letters[min(max(slot, 0), letters.count - 1)]
                    guard letter != dragged else { return }
                    dragged = letter
                    onLetter(letter)
                }
                .onEnded { _ in
                    if let dragged { onCommit(dragged) }
                    dragged = nil
                })
            .sensoryFeedback(.selection, trigger: dragged)
        }
        .frame(width: 20)
        .accessibilityLabel(Text("library.alphabetRail.label"))
        #endif
    }

    private func label(_ letter: String, isActive: Bool) -> some View {
        Text(verbatim: letter)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive || highlighted == letter ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(minWidth: 28, minHeight: 24)
            .background {
                if isActive { Circle().fill(Color.Theme.focusFill) }
            }
            .scaleEffect(isActive ? 1.3 : 1)
            .modifier(ShakeEffect(shakes: rejected?.letter == letter ? CGFloat(rejected?.attempt ?? 0) : 0))
            .animation(.default, value: rejected?.attempt)
            .animation(.snappy(duration: 0.15), value: isActive)
    }
}

#if os(tvOS)
/// The label draws its own focus state; the system lift would double it.
private struct RailLetterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(shakes * .pi * 4), y: 0))
    }
}
